//! Logica pura do render de Mermaid. Nada aqui conhece Lua nem Neovim (ADR-0001): entra
//! `&str`, sai `Vec<String>`, e e por isso que `cargo test` cobre o crate sem editor nenhum.
//!
//! Regra do projeto: sempre `Err`, nunca `panic!` deliberado. O `catch_unwind` em
//! [`render_with_notice`] existe so por defesa contra panic dentro do merman, que quebra API entre
//! versoes, e converte o panic em `Err` com mensagem.
//!
//! # Degrau de simplificacao
//!
//! O layout de texto do merman nao roteia todo flowchart: aresta que cruza a borda de um
//! subgraph, ou duas arestas de tracos diferentes (`-->` e `==>`) que se cruzam, devolvem
//! `UnsupportedFeature` (`routes crossing reserved graph geometry`, `unroutable graph edges`,
//! `mixed-stroke route junctions`), e os limites de recurso do merman cortam o resto. Medido
//! nas versoes `0.8.0-alpha.6` e `0.10.0` (V5). Em vez de devolver erro, o flowchart que falha
//! tenta de novo, nesta ordem, **tirando so o que o layout de texto nao sabe rotear**: o traco
//! das arestas (todas viram linha comum), as bordas dos subgraphs (os nos e as arestas ficam) e
//! os dois. O primeiro que desenha vence, e [`Rendered::notice`] diz o que foi simplificado.
//! Se nenhum desenha, o erro devolvido e o do diagrama como o autor escreveu.

use std::fmt;
use std::panic::{catch_unwind, AssertUnwindSafe};

use merman_ascii::{
    AsciiError, AsciiLayoutProfile, AsciiOutput, AsciiRenderOptions, AsciiRenderer,
    AsciiResourceLimitId, AsciiResourcePolicy, AsciiViewportPolicy, OverflowPolicy,
};
use merman_core::{ParseOptions, SemanticParser};
use merman_model::families::flowchart::{FlowEdgeStroke, FlowNodeProvenance, FlowchartModel};
use merman_model::runtime::OperationContext;
use merman_model::semantic::{ParsedSemanticDiagram, SemanticDiagramModel};
use merman_model::OperationControl;

/// Largura usada quando o chamador nao passa `width`.
pub const DEFAULT_WIDTH: usize = 80;

/// Teto de linhas do fonte. Acima disso o render custa 46ms ou mais (V5), entao a guarda
/// devolve erro em vez de travar o editor.
pub const DEFAULT_MAX_SRC_LINES: usize = 200;

/// Teto de unidades de trabalho do layout. O perfil `interactive` do merman para em 2 000 000, e
/// o diagrama de arquitetura do ILZA sem as bordas dos subgraphs (o caso do bug report) passa
/// disso: reprova com 2 milhoes e desenha com 4 (V5b, medido). Com 4 000 000 o pior caso (o
/// merman gasta o teto inteiro procurando rota que nao existe) custa cerca de 40 ms em release.
/// E o preco de aceitar diagramas maiores; o cache do Lua guarda o resultado, inclusive o erro.
pub const MAX_LAYOUT_WORK_UNITS: usize = 4_000_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Charset {
    Unicode,
    Ascii,
}

impl Charset {
    pub fn parse(value: &str) -> Result<Self, RenderError> {
        match value {
            "unicode" => Ok(Self::Unicode),
            "ascii" => Ok(Self::Ascii),
            other => Err(RenderError::InvalidOption(format!(
                "charset must be \"unicode\" or \"ascii\", got {other:?}"
            ))),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderOptions {
    /// Largura util da janela de preview, em celulas. E uma meta: se o layout padrao passar
    /// dela, tenta o perfil compacto, mas nunca corta. A saida pode ser mais larga.
    pub width: usize,
    pub charset: Charset,
    /// Id de tipo do Mermaid ja conhecido (por exemplo `flowchart-v2`), que pula a deteccao.
    pub diagram_ty: Option<String>,
    pub max_src_lines: usize,
}

impl Default for RenderOptions {
    fn default() -> Self {
        Self {
            width: DEFAULT_WIDTH,
            charset: Charset::Unicode,
            diagram_ty: None,
            max_src_lines: DEFAULT_MAX_SRC_LINES,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RenderError {
    /// `opts` invalido (largura zero, charset desconhecido, tipo errado).
    InvalidOption(String),
    EmptySource,
    TooLarge {
        lines: usize,
        max: usize,
    },
    /// O parser nao reconheceu nenhum diagrama no texto.
    NoDiagram,
    /// Sintaxe invalida, tipo nao detectado ou `diagram_ty` desconhecido.
    Parse(String),
    /// Diagrama valido que o renderer de texto nao cobre (por exemplo `pie`).
    Unsupported(String),
    /// Qualquer outra falha do renderer (limite de recursos, largura, alocacao).
    Render(String),
    /// Panic capturado por `catch_unwind`. Nao deveria acontecer.
    Internal(String),
}

impl fmt::Display for RenderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidOption(msg) => write!(f, "invalid option: {msg}"),
            Self::EmptySource => write!(f, "empty mermaid source"),
            Self::TooLarge { lines, max } => write!(
                f,
                "mermaid source too large: {lines} lines exceeds the limit of {max} (max_src_lines)"
            ),
            Self::NoDiagram => write!(f, "no mermaid diagram found in the source"),
            Self::Parse(msg) => write!(f, "mermaid parse error: {msg}"),
            Self::Unsupported(msg) => write!(f, "unsupported diagram: {msg}"),
            Self::Render(msg) => write!(f, "mermaid render failed: {msg}"),
            Self::Internal(msg) => write!(f, "internal error (panic caught): {msg}"),
        }
    }
}

impl std::error::Error for RenderError {}

thread_local! {
    // Montar o parser carrega a configuracao padrao do Mermaid; fazer isso a cada chamada seria
    // desperdicio. Thread-local porque o Lua do Neovim e single-thread e nao precisamos de
    // `Sync`. A politica de runtime dele e a deterministica: relogio fixo, sem estado do sistema.
    static PARSER: SemanticParser = SemanticParser::new();
}

/// O desenho de um diagrama e, quando o layout teve que ser simplificado, o aviso do que se
/// perdeu (veja "Degrau de simplificacao" no topo do modulo).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rendered {
    pub lines: Vec<String>,
    /// `None` quando o desenho e fiel ao que o autor escreveu.
    pub notice: Option<String>,
}

/// Tipos de diagrama que o renderer de texto cobre, lidos do merman em runtime.
pub fn supported_types() -> Vec<String> {
    merman_ascii::ascii_supported_diagram_types()
        .iter()
        .map(|ty| (*ty).to_string())
        .collect()
}

/// Renderiza `src` em linhas de texto e diz se o layout foi simplificado para desenhar (veja
/// "Degrau de simplificacao" no topo do modulo). Nunca entra em panic: qualquer panic interno
/// vira [`RenderError::Internal`].
pub fn render_with_notice(src: &str, opts: &RenderOptions) -> Result<Rendered, RenderError> {
    guarded(|| render_inner(src, opts))
}

/// So as linhas, sem o aviso. O binding pede o aviso, entao so os testes usam esta forma.
#[cfg(test)]
pub fn render(src: &str, opts: &RenderOptions) -> Result<Vec<String>, RenderError> {
    render_with_notice(src, opts).map(|rendered| rendered.lines)
}

/// Roda `f` e converte panic em `Err`. Separado de [`render_with_notice`] para o teste poder
/// injetar um panic sem que o codigo de producao precise de nenhum `panic!` deliberado.
pub(crate) fn guarded<T>(f: impl FnOnce() -> Result<T, RenderError>) -> Result<T, RenderError> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result,
        Err(payload) => Err(RenderError::Internal(panic_message(payload.as_ref()))),
    }
}

fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(msg) = payload.downcast_ref::<&str>() {
        (*msg).to_string()
    } else if let Some(msg) = payload.downcast_ref::<String>() {
        msg.clone()
    } else {
        "unknown panic payload".to_string()
    }
}

fn render_inner(src: &str, opts: &RenderOptions) -> Result<Rendered, RenderError> {
    validate(src, opts)?;

    let parsed = parse(src, opts)?;
    let context = operation_context()?;

    let err = match draw(&parsed, opts, &context) {
        Ok(output) => return finish(output, None),
        Err(err) => err,
    };

    // So o flowchart tem degrau de simplificacao, e so para as falhas de layout: rota que nao
    // cabe (`UnsupportedFeature`) e os limites de recurso do merman, que cortam a busca de rota.
    if matches!(
        err,
        AsciiError::UnsupportedFeature { .. } | AsciiError::ResourceLimitExceeded(_)
    ) {
        for step in applicable_steps(&parsed) {
            if let Some(output) = draw_simplified(src, opts, &context, step) {
                return finish(output, Some(step.notice()));
            }
        }
    }
    Err(map_ascii_error(err))
}

/// Entrada do parser: detecta o tipo ou, com `diagram_ty`, usa o que o chamador ja sabe.
fn parse(src: &str, opts: &RenderOptions) -> Result<ParsedSemanticDiagram, RenderError> {
    PARSER.with(|parser| {
        let control = OperationControl::new();
        let outcome = match opts.diagram_ty.as_deref() {
            Some(ty) => parser
                .parse_diagram_with_type_controlled_sync(ty, src, &control)
                .map(|result| result.map(Some)),
            None => {
                let context = parser
                    .begin_operation()
                    .map_err(|err| RenderError::Render(tidy(err.to_string())))?;
                parser.parse_diagram_with_options_controlled_in_context_sync(
                    src,
                    ParseOptions::strict(),
                    &control,
                    &context,
                )
            }
        };
        match outcome {
            Ok(Ok(Some(parsed))) => Ok(parsed),
            Ok(Ok(None)) => Err(RenderError::NoDiagram),
            Ok(Err(err)) => Err(RenderError::Parse(tidy(err.to_string()))),
            Err(cancelled) => Err(RenderError::Render(tidy(format!("{cancelled:?}")))),
        }
    })
}

/// Contexto de runtime do render (relogio fixo: o `gantt` nao enxerga a data de hoje).
fn operation_context() -> Result<OperationContext, RenderError> {
    PARSER
        .with(SemanticParser::begin_operation)
        .map_err(|err| RenderError::Render(tidy(err.to_string())))
}

/// Desenha o modelo, e `width` e uma meta, nao um corte: o merman nunca trunca (perderia dado).
/// Se o layout canonico passou da meta, tenta o perfil compacto, que so flowchart e sequence
/// aceitam. Para as outras familias o erro de admissao e barato e e ignorado de proposito.
fn draw(
    parsed: &ParsedSemanticDiagram,
    opts: &RenderOptions,
    context: &OperationContext,
) -> Result<AsciiOutput, AsciiError> {
    let mut output = render_model(parsed, opts, context, AsciiLayoutProfile::Canonical)?;
    if output.overflowed {
        if let Ok(compact) = render_model(parsed, opts, context, AsciiLayoutProfile::Compact) {
            if compact.emitted_extent.width < output.emitted_extent.width {
                output = compact;
            }
        }
    }
    Ok(output)
}

fn finish(output: AsciiOutput, notice: Option<String>) -> Result<Rendered, RenderError> {
    let lines: Vec<String> = output.text.lines().map(str::to_owned).collect();
    // Diagrama so com cabecalho e valido para o parser mas nao desenha nada. Devolver zero
    // linhas faria o bloco sumir do preview sem explicacao, entao vira erro e o chamador
    // degrada para codigo cru.
    if lines.iter().all(|line| line.trim().is_empty()) {
        return Err(RenderError::Render(
            "diagram produced no output (header only?)".into(),
        ));
    }

    // Linha mais larga que `width` pode sobrar. Quem decide o que fazer com ela e o Lua.
    Ok(Rendered { lines, notice })
}

/// O que o degrau de simplificacao pode tirar do flowchart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Simplify {
    /// Toda aresta vira linha comum (tira o pontilhado e o grosso).
    strokes: bool,
    /// Tira as bordas dos subgraphs; os nos e as arestas ficam.
    subgraphs: bool,
}

impl Simplify {
    fn notice(self) -> String {
        match (self.subgraphs, self.strokes) {
            (true, true) => "layout simplified: subgraph boxes removed and edge styles flattened, the text layout cannot route them".into(),
            (true, false) => "layout simplified: subgraph boxes removed, the text layout cannot route edges across them".into(),
            (false, _) => "layout simplified: edge styles flattened, the text layout cannot route mixed styles that cross".into(),
        }
    }
}

/// Os degraus que fazem sentido para este diagrama, do que perde menos ao que perde mais: so o
/// traco, so os subgraphs, os dois. Vazio se nao e flowchart ou se nao ha nada a tirar.
fn applicable_steps(parsed: &ParsedSemanticDiagram) -> Vec<Simplify> {
    let SemanticDiagramModel::Flowchart(model) = &parsed.model else {
        return Vec::new();
    };
    let strokes = model
        .edges
        .iter()
        .any(|edge| edge.stroke_kind != FlowEdgeStroke::Normal);
    let subgraphs = !model.subgraphs.is_empty();
    let mut steps = Vec::new();
    if strokes {
        steps.push(Simplify {
            strokes: true,
            subgraphs: false,
        });
    }
    if subgraphs {
        steps.push(Simplify {
            strokes: false,
            subgraphs: true,
        });
    }
    if strokes && subgraphs {
        steps.push(Simplify {
            strokes: true,
            subgraphs: true,
        });
    }
    steps
}

/// Parseia de novo (o modelo do merman nao e `Clone`, e parsear custa ~100 us), tira o que o
/// degrau manda e desenha. `None` se algo falhar: quem chama devolve o erro original.
fn draw_simplified(
    src: &str,
    opts: &RenderOptions,
    context: &OperationContext,
    step: Simplify,
) -> Option<AsciiOutput> {
    let mut parsed = parse(src, opts).ok()?;
    let SemanticDiagramModel::Flowchart(model) = &mut parsed.model else {
        return None;
    };
    simplify(model, step);
    draw(&parsed, opts, context).ok()
}

fn simplify(model: &mut FlowchartModel, step: Simplify) {
    if step.strokes {
        for edge in &mut model.edges {
            edge.stroke_kind = FlowEdgeStroke::Normal;
            edge.stroke = Some("normal".to_string());
        }
    }
    if step.subgraphs {
        // Aresta ligada a um subgraph termina num no "ancora" que o parser fabrica. Sem a borda,
        // a ancora vira um no comum com o titulo do subgraph, para a aresta nao perder o rotulo.
        for node in &mut model.nodes {
            if node.provenance != FlowNodeProvenance::SubgraphAnchor {
                continue;
            }
            if let Some(subgraph) = model.subgraphs.iter().find(|sg| sg.id == node.id) {
                node.label = Some(subgraph.title.clone());
                node.provenance = FlowNodeProvenance::Authored;
            }
        }
        model.subgraphs.clear();
        // O CSS que um vertice herda de um subgraph de mesmo id aponta para a ordem dos
        // subgraphs, que acabou de sumir: o merman recusaria o modelo.
        model.subgraph_vertex_styles = Default::default();
    }
}

/// Teto de caracteres das mensagens vindas do merman. O parser repete o fonte inteiro em
/// alguns erros, e um diagrama de 200 linhas nao cabe em uma notificacao.
const MAX_MESSAGE_CHARS: usize = 300;

/// Deixa a mensagem do merman em uma linha so e com tamanho limitado.
fn tidy(msg: String) -> String {
    let one_line = msg.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= MAX_MESSAGE_CHARS {
        return one_line;
    }
    let mut out: String = one_line.chars().take(MAX_MESSAGE_CHARS).collect();
    out.push_str("...");
    out
}

/// Um render completo do modelo ja parseado, com a politica de overflow `Allow`.
///
/// Nao usamos `OverflowPolicy::Fallback`: para flowchart e xychart ele troca o desenho por um
/// dump estruturado quase ilegivel (medido na fase 6), pior do que uma linha larga.
fn render_model(
    parsed: &ParsedSemanticDiagram,
    opts: &RenderOptions,
    context: &OperationContext,
    profile: AsciiLayoutProfile,
) -> Result<AsciiOutput, AsciiError> {
    let ascii_opts = match opts.charset {
        Charset::Unicode => AsciiRenderOptions::unicode(),
        Charset::Ascii => AsciiRenderOptions::ascii(),
    }
    .with_layout_profile(profile);
    let renderer = AsciiRenderer::new(ascii_opts)?;
    let control = OperationControl::new();
    let viewport = AsciiViewportPolicy::with_max_width(opts.width).overflow(OverflowPolicy::Allow);

    renderer.render_parsed_report(parsed, viewport, &control, context, resource_policy())
}

/// O perfil `interactive` do merman com o teto de trabalho de layout em
/// [`MAX_LAYOUT_WORK_UNITS`]. O valor esta acima do minimo do limite, entao `with_limit` nao
/// falha; se um dia falhar, vale o perfil sem o ajuste, que e so mais restritivo.
fn resource_policy() -> AsciiResourcePolicy {
    AsciiResourcePolicy::default()
        .with_limit(
            AsciiResourceLimitId::MaxLayoutWorkUnits,
            MAX_LAYOUT_WORK_UNITS,
        )
        .unwrap_or_default()
}

fn validate(src: &str, opts: &RenderOptions) -> Result<(), RenderError> {
    if opts.width == 0 {
        return Err(RenderError::InvalidOption(
            "width must be at least 1".into(),
        ));
    }
    if src.trim().is_empty() {
        return Err(RenderError::EmptySource);
    }
    let lines = src.lines().count();
    if lines > opts.max_src_lines {
        return Err(RenderError::TooLarge {
            lines,
            max: opts.max_src_lines,
        });
    }
    Ok(())
}

fn map_ascii_error(err: AsciiError) -> RenderError {
    match err {
        AsciiError::UnsupportedDiagram { .. } | AsciiError::UnsupportedFeature { .. } => {
            RenderError::Unsupported(tidy(err.to_string()))
        }
        other => RenderError::Render(tidy(other.to_string())),
    }
}
