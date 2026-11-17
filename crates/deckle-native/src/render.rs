//! Logica pura do render de Mermaid. Nada aqui conhece Lua nem Neovim (ADR-0001): entra
//! `&str`, sai `Vec<String>`, e e por isso que `cargo test` cobre o crate sem editor nenhum.
//!
//! Regra do projeto: sempre `Err`, nunca `panic!` deliberado. O `catch_unwind` em
//! [`render`] existe so por defesa contra panic dentro do merman, que e alpha, e converte o
//! panic em `Err` com mensagem.

use std::fmt;
use std::panic::{catch_unwind, AssertUnwindSafe};

use merman_ascii::{
    AsciiError, AsciiLayoutProfile, AsciiOutput, AsciiRenderOptions, AsciiRenderer,
    AsciiResourcePolicy, AsciiViewportPolicy, OverflowPolicy,
};
use merman_core::runtime::RuntimePolicy;
use merman_core::{Engine, OperationControl, ParseOptions, ParsedDiagramRender};

/// Largura usada quando o chamador nao passa `width`.
pub const DEFAULT_WIDTH: usize = 80;

/// Teto de linhas do fonte. Acima disso o render custa 46ms ou mais (V5), entao a guarda
/// devolve erro em vez de travar o editor.
pub const DEFAULT_MAX_SRC_LINES: usize = 200;

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
    // Montar o Engine registra todos os parsers; fazer isso a cada chamada seria desperdicio.
    // Thread-local porque o Lua do Neovim e single-thread e nao precisamos de `Sync`.
    static ENGINE: Engine = Engine::new();
}

/// Tipos de diagrama que o renderer de texto cobre, lidos do merman em runtime.
pub fn supported_types() -> Vec<String> {
    merman_ascii::ascii_supported_diagram_types()
        .iter()
        .map(|ty| (*ty).to_string())
        .collect()
}

/// Renderiza `src` em linhas de texto. Nunca entra em panic: qualquer panic interno vira
/// [`RenderError::Internal`].
pub fn render(src: &str, opts: &RenderOptions) -> Result<Vec<String>, RenderError> {
    guarded(|| render_inner(src, opts))
}

/// Roda `f` e converte panic em `Err`. Separado de [`render`] para o teste poder injetar um
/// panic sem que o codigo de producao precise de nenhum `panic!` deliberado.
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

fn render_inner(src: &str, opts: &RenderOptions) -> Result<Vec<String>, RenderError> {
    validate(src, opts)?;

    let parse_opts = ParseOptions::strict();
    let parsed = ENGINE
        .with(|engine| match opts.diagram_ty.as_deref() {
            Some(ty) => engine.parse_diagram_for_render_model_with_type_sync(ty, src, parse_opts),
            None => engine.parse_diagram_for_render_model_sync(src, parse_opts),
        })
        .map_err(|err| RenderError::Parse(tidy(err.to_string())))?
        .ok_or(RenderError::NoDiagram)?;

    let mut output = render_model(&parsed, opts, AsciiLayoutProfile::Canonical)?;

    // `width` e uma meta, nao um corte: o merman nunca trunca (perderia dado). Se o layout
    // canonico passou da meta, tenta o perfil compacto, que so flowchart e sequence aceitam.
    // Para as outras familias o erro de admissao e barato e e ignorado de proposito.
    if output.overflowed {
        if let Ok(compact) = render_model(&parsed, opts, AsciiLayoutProfile::Compact) {
            if compact.emitted_extent.width < output.emitted_extent.width {
                output = compact;
            }
        }
    }

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
    Ok(lines)
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
    parsed: &ParsedDiagramRender,
    opts: &RenderOptions,
    profile: AsciiLayoutProfile,
) -> Result<AsciiOutput, RenderError> {
    let ascii_opts = match opts.charset {
        Charset::Unicode => AsciiRenderOptions::unicode(),
        Charset::Ascii => AsciiRenderOptions::ascii(),
    }
    .with_layout_profile(profile);
    let renderer = AsciiRenderer::new(ascii_opts).map_err(map_ascii_error)?;
    let control = OperationControl::new();
    let context = RuntimePolicy::deterministic()
        .begin_operation()
        .map_err(|err| RenderError::Render(tidy(err.to_string())))?;
    let viewport = AsciiViewportPolicy::with_max_width(opts.width).overflow(OverflowPolicy::Allow);

    renderer
        .render_model_report(
            parsed.model(),
            viewport,
            &control,
            &context,
            AsciiResourcePolicy::default(),
        )
        .map_err(map_ascii_error)
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
