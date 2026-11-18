//! Testes da logica pura. Rodam com `cargo test`, sem Lua e sem Neovim.

use std::fmt::Write as _;
use std::time::{Duration, Instant};

use crate::render::{
    guarded, render, render_with_notice, supported_types, Charset, RenderError, RenderOptions,
    Rendered, DEFAULT_MAX_SRC_LINES, MAX_LAYOUT_WORK_UNITS,
};

/// Um diagrama minimo por familia que `ascii_supported_diagram_types()` anuncia. A chave e o
/// nome da familia no merman, nao a palavra-chave do Mermaid.
const MINIMAL: &[(&str, &str)] = &[
    (
        "class",
        "classDiagram\n  class Animal\n  class Duck\n  Animal <|-- Duck",
    ),
    ("er", "erDiagram\n  CUSTOMER ||--o{ ORDER : places"),
    ("flowchart", "flowchart TD\n  A --> B"),
    (
        "gantt",
        "gantt\n  dateFormat YYYY-MM-DD\n  section Work\n  Task one :a1, 2024-01-01, 3d",
    ),
    ("gitgraph", "gitGraph\n  commit\n  commit"),
    (
        "journey",
        "journey\n  title Day\n  section Work\n    Code: 5: Me",
    ),
    ("kanban", "kanban\n  todo[Todo]\n    t1[Task one]"),
    ("mindmap", "mindmap\n  root((Root))\n    A\n    B"),
    (
        "packet",
        "packet-beta\n  0-15: \"Source Port\"\n  16-31: \"Destination Port\"",
    ),
    ("sequence", "sequenceDiagram\n  Alice->>John: Hello"),
    ("state", "stateDiagram-v2\n  [*] --> A\n  A --> [*]"),
    ("timeline", "timeline\n  title History\n  2002 : LinkedIn"),
    ("treeView", "treeView-beta\n  \"root\"\n    \"child\""),
    (
        "xychart",
        "xychart-beta\n  x-axis [a, b]\n  y-axis \"Y\" 0 --> 10\n  bar [3, 7]",
    ),
];

fn opts() -> RenderOptions {
    RenderOptions {
        width: 120,
        ..RenderOptions::default()
    }
}

fn ascii_opts() -> RenderOptions {
    RenderOptions {
        charset: Charset::Ascii,
        ..opts()
    }
}

fn err_of(src: &str, opts: &RenderOptions) -> RenderError {
    match render(src, opts) {
        Ok(lines) => panic!(
            "expected Err, got Ok with {} lines:\n{}",
            lines.len(),
            lines.join("\n")
        ),
        Err(err) => err,
    }
}

/// Mensagem legivel: nao vazia, sem ruido de panic e sem despejar o fonte inteiro.
fn assert_readable(err: &RenderError) {
    let msg = err.to_string();
    assert!(!msg.trim().is_empty(), "empty error message for {err:?}");
    assert!(!msg.contains("panicked"), "message leaks a panic: {msg}");
    assert!(
        msg.chars().count() <= 400,
        "message too long ({}): {msg}",
        msg.len()
    );
}

// --- gate 1: os 14 tipos -------------------------------------------------------------------

#[test]
fn fixtures_cover_exactly_the_supported_types() {
    let mut supported = supported_types();
    supported.sort();
    let mut fixtures: Vec<String> = MINIMAL.iter().map(|(ty, _)| (*ty).to_string()).collect();
    fixtures.sort();
    assert_eq!(
        fixtures, supported,
        "o merman mudou a lista de tipos suportados: ajuste MINIMAL"
    );
    assert_eq!(supported.len(), 14);
}

#[test]
fn every_supported_type_renders_a_minimal_diagram() {
    let mut failures = Vec::new();
    for (family, src) in MINIMAL {
        match render(src, &opts()) {
            Ok(lines) if lines.iter().any(|l| !l.trim().is_empty()) => {}
            Ok(_) => failures.push(format!("{family}: rendered only blank lines")),
            Err(err) => failures.push(format!("{family}: {err}")),
        }
    }
    assert!(
        failures.is_empty(),
        "families that failed:\n{}",
        failures.join("\n")
    );
}

#[test]
fn every_supported_type_renders_with_ascii_charset() {
    let mut failures = Vec::new();
    for (family, src) in MINIMAL {
        match render(src, &ascii_opts()) {
            Ok(lines) => {
                if let Some(bad) = lines.iter().find(|l| !l.is_ascii()) {
                    failures.push(format!("{family}: non-ASCII output: {bad:?}"));
                }
            }
            Err(err) => failures.push(format!("{family}: {err}")),
        }
    }
    assert!(
        failures.is_empty(),
        "families that failed:\n{}",
        failures.join("\n")
    );
}

#[test]
fn unicode_charset_draws_box_characters() {
    let lines = render("flowchart TD\n  A --> B", &opts()).unwrap();
    assert!(lines.iter().any(|l| l.contains('┌')), "{lines:?}");
    let lines = render("flowchart TD\n  A --> B", &ascii_opts()).unwrap();
    assert!(lines.iter().any(|l| l.contains('+')), "{lines:?}");
}

// --- gate 2: entrada ruim devolve Err legivel ----------------------------------------------

#[test]
fn empty_and_blank_source_are_errors() {
    for src in ["", "   ", "\n\n", " \t\n "] {
        let err = err_of(src, &opts());
        assert_eq!(err, RenderError::EmptySource, "src = {src:?}");
        assert_readable(&err);
    }
}

#[test]
fn malformed_source_is_an_error_with_a_readable_message() {
    let cases = [
        ("prose", "this is not mermaid at all"),
        ("flowchart dangling edge", "flowchart TD\n  A -->"),
        (
            "flowchart unterminated label",
            "flowchart TD\n  A --> B[unclosed",
        ),
        ("sequence dangling arrow", "sequenceDiagram\n  Alice->>"),
        ("class open brace", "classDiagram\n  class {"),
        (
            "unclosed front-matter",
            "---\ntitle: x\nflowchart TD\n  A-->B",
        ),
    ];
    for (name, src) in cases {
        let err = err_of(src, &opts());
        assert!(matches!(err, RenderError::Parse(_)), "{name}: {err:?}");
        assert!(
            err.to_string().starts_with("mermaid parse error:"),
            "{name}: {err}"
        );
        assert_readable(&err);
    }
}

#[test]
fn parse_error_does_not_echo_a_huge_source() {
    let mut src = String::from("this is not a diagram\n");
    for i in 0..150 {
        writeln!(
            src,
            "line number {i} of prose that is definitely not mermaid"
        )
        .unwrap();
    }
    let err = err_of(&src, &opts());
    assert_readable(&err);
}

#[test]
fn header_only_diagram_is_an_error_not_an_empty_render() {
    let err = err_of("flowchart TD", &opts());
    assert!(matches!(err, RenderError::Render(_)), "{err:?}");
    assert!(err.to_string().contains("no output"), "{err}");
}

#[test]
fn unsupported_diagram_type_is_an_error_naming_the_type() {
    let cases = [
        "pie title Pets\n  \"Dogs\" : 386\n  \"Cats\" : 85",
        "C4Context\n  title X",
    ];
    for src in cases {
        let err = err_of(src, &opts());
        assert!(matches!(err, RenderError::Unsupported(_)), "{err:?}");
        assert!(err.to_string().starts_with("unsupported diagram:"), "{err}");
        assert_readable(&err);
    }
    assert!(err_of(cases[0], &opts()).to_string().contains("pie"));
}

#[test]
fn source_above_the_size_guard_is_an_error() {
    let limit = DEFAULT_MAX_SRC_LINES;
    let build = |edges: usize| {
        let mut src = String::from("flowchart TD\n");
        for i in 0..edges {
            writeln!(src, "  N{i} --> N{}", i + 1).unwrap();
        }
        src
    };

    // Exatamente no limite passa na guarda: 1 linha de cabecalho + (limit - 1) arestas.
    let at_limit = build(limit - 1);
    assert_eq!(at_limit.lines().count(), limit);
    assert!(
        !matches!(
            render(&at_limit, &opts()),
            Err(RenderError::TooLarge { .. })
        ),
        "a fonte no limite nao pode ser barrada pela guarda"
    );

    // Uma linha acima e barrada antes de qualquer trabalho de layout.
    let over = build(limit);
    let started = Instant::now();
    let err = err_of(&over, &opts());
    assert!(
        started.elapsed() < Duration::from_millis(50),
        "a guarda tem que ser barata"
    );
    assert_eq!(
        err,
        RenderError::TooLarge {
            lines: limit + 1,
            max: limit
        }
    );
    let msg = err.to_string();
    assert!(
        msg.contains(&(limit + 1).to_string()) && msg.contains(&limit.to_string()),
        "{msg}"
    );
    assert_readable(&err);
}

#[test]
fn size_guard_honors_a_custom_limit() {
    let o = RenderOptions {
        max_src_lines: 2,
        ..opts()
    };
    assert!(render("flowchart TD\n  A --> B", &o).is_ok());
    let err = err_of("flowchart TD\n  A --> B\n  B --> C", &o);
    assert_eq!(err, RenderError::TooLarge { lines: 3, max: 2 });
}

#[test]
fn invalid_width_is_an_error() {
    let o = RenderOptions { width: 0, ..opts() };
    let err = err_of("flowchart TD\n  A --> B", &o);
    assert!(matches!(err, RenderError::InvalidOption(_)), "{err:?}");
    assert_readable(&err);
}

#[test]
fn charset_parse_rejects_unknown_values() {
    assert_eq!(Charset::parse("unicode"), Ok(Charset::Unicode));
    assert_eq!(Charset::parse("ascii"), Ok(Charset::Ascii));
    for bad in ["", "auto", "UNICODE", "utf8"] {
        let err = Charset::parse(bad).unwrap_err();
        assert!(
            matches!(err, RenderError::InvalidOption(_)),
            "{bad}: {err:?}"
        );
        assert_readable(&err);
    }
}

// --- diagram_ty ----------------------------------------------------------------------------

#[test]
fn diagram_ty_skips_detection_for_known_types() {
    for (ty, src) in [
        ("flowchart", "flowchart TD\n  A --> B"),
        ("flowchart-v2", "flowchart TD\n  A --> B"),
        ("sequence", "sequenceDiagram\n  A->>B: hi"),
    ] {
        let o = RenderOptions {
            diagram_ty: Some(ty.to_string()),
            ..opts()
        };
        let lines = render(src, &o).unwrap_or_else(|e| panic!("{ty}: {e}"));
        assert!(!lines.is_empty(), "{ty}");
    }
}

#[test]
fn unknown_diagram_ty_is_an_error() {
    let o = RenderOptions {
        diagram_ty: Some("nope".to_string()),
        ..opts()
    };
    let err = err_of("flowchart TD\n  A --> B", &o);
    assert!(err.to_string().contains("nope"), "{err}");
    assert_readable(&err);
}

// --- panic guard ---------------------------------------------------------------------------

#[test]
fn guarded_turns_a_panic_into_an_error() {
    // O unico `panic!` do crate e este, dentro do teste: injeta o panic que o merman poderia
    // soltar, sem deixar nenhum `panic!` no codigo de producao.
    let result: Result<(), RenderError> = guarded(|| panic!("layout impossible: cycle unresolved"));
    match result {
        Err(RenderError::Internal(msg)) => assert!(msg.contains("cycle unresolved"), "{msg}"),
        other => panic!("expected Internal, got {other:?}"),
    }

    let owned: Result<(), RenderError> = guarded(|| panic!("{}", String::from("owned payload")));
    assert!(matches!(owned, Err(RenderError::Internal(m)) if m.contains("owned payload")));
}

#[test]
fn guarded_passes_results_through() {
    assert_eq!(guarded(|| Ok(7)), Ok(7));
    assert_eq!(
        guarded::<()>(|| Err(RenderError::EmptySource)),
        Err(RenderError::EmptySource)
    );
}

#[test]
fn render_is_usable_after_an_error() {
    assert!(render("", &opts()).is_err());
    assert!(render("nonsense", &opts()).is_err());
    assert!(render("flowchart TD\n  A --> B", &opts()).is_ok());
}

// --- texto largo e nao-ASCII ---------------------------------------------------------------

#[test]
fn cjk_and_emoji_labels_render_without_panicking() {
    let src = "flowchart TD\n  A[\"你好世界\"] --> B[\"🚀 launch\"]\n  B --> C[\"ありがとう\"]";
    let lines = render(src, &opts()).expect("cjk + emoji must render");
    let text = lines.join("\n");
    assert!(text.contains("你好世界"), "{text}");
    assert!(text.contains("🚀"), "{text}");
    assert!(text.contains("ありがとう"), "{text}");
}

#[test]
fn render_is_deterministic() {
    for (family, src) in MINIMAL {
        let a = render(src, &opts()).unwrap();
        let b = render(src, &opts()).unwrap();
        assert_eq!(a, b, "{family}");
    }
}

// --- width ---------------------------------------------------------------------------------

fn widest(lines: &[String]) -> usize {
    lines.iter().map(|l| l.chars().count()).max().unwrap_or(0)
}

/// Renderiza com largura folgada e com largura apertada e exige que a apertada seja mais estreita.
fn assert_tight_width_is_narrower(name: &str, src: &str) {
    let roomy = render(
        src,
        &RenderOptions {
            width: 1000,
            ..opts()
        },
    )
    .unwrap();
    let tight = render(
        src,
        &RenderOptions {
            width: 40,
            ..opts()
        },
    )
    .unwrap();
    assert!(
        widest(&tight) < widest(&roomy),
        "{name}: compact layout should be narrower: {} vs {}",
        widest(&tight),
        widest(&roomy)
    );
}

#[test]
fn width_target_picks_the_compact_layout_for_flowchart() {
    // Rotulos acima de 24 celulas quebram no perfil compacto e ficam inteiros no canonico (40).
    assert_tight_width_is_narrower(
        "flowchart",
        "flowchart LR\n  A[Collect every input from the user] --> B[Validate every field of the form]",
    );
}

#[test]
fn width_target_picks_the_compact_layout_for_sequence() {
    // O perfil compacto aperta o espacamento entre participantes de 5 para 3.
    assert_tight_width_is_narrower(
        "sequence",
        "sequenceDiagram\n  A->>B: one\n  B->>C: two\n  C->>D: three\n  D->>E: four\n  E->>F: five",
    );
}

#[test]
fn width_target_never_truncates() {
    // Mesmo sem caber, o conteudo vem inteiro. Cortar e decisao da camada Lua.
    let src = "flowchart LR\n  A[First step here] --> B[Second step here] --> C[Third step here]";
    let lines = render(src, &RenderOptions { width: 5, ..opts() }).unwrap();
    let text = lines.join("\n");
    for needle in ["First", "Second", "Third"] {
        assert!(text.contains(needle), "lost {needle}:\n{text}");
    }
}

#[test]
fn families_without_a_compact_profile_still_render_when_too_wide() {
    let src = "classDiagram\n  class Animal\n  class Duck\n  Animal <|-- Duck";
    let lines = render(src, &RenderOptions { width: 3, ..opts() }).unwrap();
    assert!(!lines.is_empty());
}

// --- layout simplificado (flowchart) --------------------------------------------------------

/// Reducao do bug report (o diagrama de arquitetura do README do ILZA): nenhuma versao do merman
/// que medimos (`0.8.0-alpha.6`, `0.10.0`) roteia a aresta que sai de um subgraph para um no solto
/// (`routes crossing reserved graph geometry`). O texto e o que sobrou depois de tirar linhas
/// ate o erro sumir, por isso os subgraphs vazios.
const GROUP_EDGES: &str = r#"flowchart TB
    subgraph Cliente["🖥️ Cliente"]
    end
    subgraph API["⚡ FastAPI — API REST :8000"]
        subgraph Modules["Módulos da Aplicação"]
            subgraph AuthMod["🔐 Auth Module"]
            end
            subgraph PatientsMod["👤 Patients Module"]
            end
        end
    end
    subgraph AI["🧠 Domínio IA (ai/)"]
        subgraph Agents["Agentes"]
        end
        subgraph AISupport["Suporte IA"]
        end
    end
    subgraph Temporal["⏱️ Temporal.io"]
    end
    subgraph Infra["🏗️ Infraestrutura"]
    end
    subgraph External["☁️ Serviços Externos"]
    end
    API -->|"Start Workflow"| TEMPORAL_SRV
    TOOL -->|"Upload PDF"| S3
"#;

/// Reducao do showcase: aresta cheia, grossa, pontilhada e com marcador que se cruzam
/// (`mixed-stroke route junctions`).
const MIXED_STROKES: &str = r"flowchart TB
    N1[Retângulo]
    N2(Arredondado)
    N3([Estádio])
    N4[[Sub-rotina]]
    N5[(Banco de dados)]
    N6((Círculo))
    N7>Assimétrico]
    N8{Decisão}
    N9{{Hexágono}}
    N10[/Paralelogramo/]
    N11[\Paralelogramo alt\]
    N12[/Trapézio\]
    N13[\Trapézio alt/]
    N14(((Círculo duplo)))

    N13 --- N14
    N3 ===> N10
    N6 o--o N13
    N7 x--x N14
";

/// Flowchart sem subgraph e sem traco misto que o merman nao consegue rotear
/// (`unroutable graph edges`): o degrau de simplificacao nao tem o que tirar.
fn dense_flowchart() -> String {
    let mut src = String::from("flowchart TD\n");
    for layer in 0..5 {
        for i in 0..8 {
            for d in 0..3 {
                writeln!(src, "  L{layer}N{i} --> L{}N{}", layer + 1, (i * 3 + d) % 8).unwrap();
            }
        }
    }
    src
}

fn rendered(src: &str, opts: &RenderOptions) -> Rendered {
    render_with_notice(src, opts).unwrap_or_else(|err| panic!("expected Ok, got {err}"))
}

#[test]
fn a_flowchart_the_layout_can_route_is_drawn_as_written() {
    let r = rendered(
        "flowchart TD\n  subgraph G[Grupo]\n    A --> B\n  end\n  B ==> C",
        &opts(),
    );
    assert_eq!(r.notice, None);
    let text = r.lines.join("\n");
    assert!(
        text.contains("Grupo"),
        "a borda do subgraph tem que ficar:\n{text}"
    );
}

#[test]
fn edges_crossing_group_borders_are_drawn_without_the_boxes() {
    // O diagrama como escrito nao roteia: sem o degrau de simplificacao seria `Err`.
    let r = rendered(GROUP_EDGES, &opts());
    let notice = r.notice.expect("o layout foi simplificado");
    assert!(notice.contains("subgraph boxes removed"), "{notice}");
    assert!(!notice.contains("edge styles"), "{notice}");
    let text = r.lines.join("\n");
    // A aresta ligada a um subgraph termina num no com o titulo dele, e o rotulo fica.
    assert!(text.contains("FastAPI"), "{text}");
    assert!(text.contains("Start Workflow"), "{text}");
    assert!(text.contains("Upload PDF"), "{text}");
    assert!(text.contains("TEMPORAL_SRV"), "{text}");
}

#[test]
fn edges_of_different_strokes_that_cross_are_drawn_as_plain_lines() {
    let r = rendered(MIXED_STROKES, &opts());
    let notice = r.notice.expect("o layout foi simplificado");
    assert!(notice.contains("edge styles flattened"), "{notice}");
    assert!(!notice.contains("subgraph"), "{notice}");
    // Nenhum no some: o que se perde e so o traco.
    let text = r.lines.join("\n");
    for label in ["Retângulo", "Círculo duplo", "Trapézio alt", "Assimétrico"] {
        assert!(text.contains(label), "{label}:\n{text}");
    }
}

#[test]
fn simplification_works_in_the_ascii_charset_too() {
    for src in [GROUP_EDGES, MIXED_STROKES] {
        let r = rendered(src, &ascii_opts());
        assert!(r.notice.is_some());
        // Os rotulos do autor tem emoji e acento, e o merman nao os troca: o que o charset
        // ASCII garante e que o resto (moldura, setas) sai sem caractere de caixa.
        let text = r.lines.join("\n");
        assert!(
            text.chars().all(|c| c.is_ascii() || src.contains(c)),
            "{text}"
        );
        assert!(text.contains('+') && text.contains('-'), "{text}");
    }
}

#[test]
fn render_without_a_notice_is_the_plain_lines() {
    // `render` e `render_with_notice` desenham o mesmo, o aviso so vem junto.
    for src in [GROUP_EDGES, MIXED_STROKES] {
        assert_eq!(render(src, &opts()).unwrap(), rendered(src, &opts()).lines);
    }
}

#[test]
fn an_unroutable_flowchart_with_nothing_to_remove_keeps_the_original_error() {
    let src = dense_flowchart();
    assert!(src.lines().count() < DEFAULT_MAX_SRC_LINES);
    let err = err_of(&src, &opts());
    assert!(matches!(err, RenderError::Unsupported(_)), "{err:?}");
    assert!(err.to_string().contains("unroutable graph edges"), "{err}");
    assert_readable(&err);
}

#[test]
fn only_the_flowchart_has_a_simplification_step() {
    // Estado composto com aresta de volta: o merman nao roteia (`state`), e nao ha degrau para
    // ele. Se uma versao futura roteia, este teste falha e o doc/deckle.txt tem que mudar.
    let src = "stateDiagram-v2\n  [*] --> Aberto\n  state Aberto {\n    [*] --> Ocioso\n    \
               Ocioso --> Renderizando\n    Renderizando --> Ocioso\n  }\n  Aberto --> [*]";
    let err = err_of(src, &opts());
    assert!(matches!(err, RenderError::Unsupported(_)), "{err:?}");
    let msg = err.to_string();
    assert!(
        msg.contains("routes crossing reserved graph geometry"),
        "{msg}"
    );
    assert!(msg.contains("`state`"), "{msg}");
}

#[test]
fn the_layout_work_ceiling_is_above_the_merman_default() {
    let default = merman_ascii::AsciiResourcePolicy::default()
        .value(merman_ascii::AsciiResourceLimitId::MaxLayoutWorkUnits)
        .expect("o perfil interativo tem teto");
    assert!(
        MAX_LAYOUT_WORK_UNITS > default,
        "{MAX_LAYOUT_WORK_UNITS} <= {default}"
    );
}

// --- examples/mermaid.md: o showcase e o teste -----------------------------------------------

const SHOWCASE: &str = include_str!("../../../examples/mermaid.md");
const ILZA_ARCHITECTURE: &str = include_str!("../tests/fixtures/ilza_architecture.mmd");
const ILZA_MODULES: &str = include_str!("../tests/fixtures/ilza_modules.mmd");

#[derive(Debug)]
struct ShowcaseBlock {
    /// Titulo (`##` ou `###`) mais proximo acima do bloco, para a mensagem de falha.
    title: String,
    /// Familia do merman (a chave de `supported_types()`), ou a palavra-chave se nao e coberta.
    family: String,
    source: String,
}

/// Os blocos ```` ```mermaid ```` de `examples/mermaid.md`, na ordem.
fn showcase_blocks() -> Vec<ShowcaseBlock> {
    let mut blocks = Vec::new();
    let mut title = String::new();
    let mut current: Option<String> = None;
    for line in SHOWCASE.lines() {
        match current.as_mut() {
            Some(source) if line.trim_end() == "```" => {
                let keyword = source
                    .split(|c: char| c.is_whitespace())
                    .next()
                    .unwrap_or_default();
                blocks.push(ShowcaseBlock {
                    title: title.clone(),
                    family: family_of(keyword),
                    source: std::mem::take(source),
                });
                current = None;
            }
            Some(source) => {
                source.push_str(line);
                source.push('\n');
            }
            None if line.trim_end() == "```mermaid" => current = Some(String::new()),
            None => {
                if let Some(heading) = line.strip_prefix("### ").or(line.strip_prefix("## ")) {
                    title = heading.trim().to_string();
                }
            }
        }
    }
    assert!(current.is_none(), "cerca ```mermaid sem fechar");
    blocks
}

/// Palavra-chave de abertura do Mermaid para o nome da familia no merman.
fn family_of(keyword: &str) -> String {
    match keyword {
        "flowchart" | "graph" => "flowchart",
        "sequenceDiagram" => "sequence",
        "classDiagram" => "class",
        "stateDiagram" | "stateDiagram-v2" => "state",
        "erDiagram" => "er",
        "gitGraph" => "gitgraph",
        "packet" | "packet-beta" => "packet",
        "treeView-beta" | "treeView" => "treeView",
        "xychart-beta" | "xychart" => "xychart",
        other => other,
    }
    .to_string()
}

fn is_ilza(block: &ShowcaseBlock) -> bool {
    [ILZA_ARCHITECTURE, ILZA_MODULES]
        .iter()
        .any(|fixture| block.source.trim_end() == fixture.trim_end())
}

/// O unico bloco do showcase que degrada, de proposito (secao "Degradacao esperada").
fn is_expected_to_degrade(block: &ShowcaseBlock) -> bool {
    block.family == "pie"
}

fn drawn_blocks() -> Vec<ShowcaseBlock> {
    showcase_blocks()
        .into_iter()
        .filter(|block| !is_expected_to_degrade(block))
        .collect()
}

#[test]
fn the_showcase_has_a_diagram_for_each_of_the_14_types() {
    let blocks = showcase_blocks();
    for ty in supported_types() {
        let count = blocks.iter().filter(|b| b.family == ty).count();
        assert!(count >= 1, "o showcase nao tem diagrama do tipo `{ty}`");
    }
    // O que o showcase promete de cada familia grande, alem de "ter um":
    let count = |family: &str| blocks.iter().filter(|b| b.family == family).count();
    assert!(
        count("flowchart") >= 7,
        "TB, LR, RL, BT, 50+ nos, @{{ shape }} e os do ILZA"
    );
    assert!(
        count("state") >= 2,
        "uma maquina grande e um estado composto"
    );
    assert_eq!(count("pie"), 1, "um `pie` para provar a degradacao");
}

#[test]
fn the_showcase_covers_the_features_it_promises() {
    let all: String = showcase_blocks()
        .iter()
        .map(|b| b.source.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    // flowchart: formas, arestas, subgraph com direcao, estilo e clique.
    for needle in [
        "N14(((",
        "N7>",
        "N12[/",
        "N13[\\",
        "{{",
        "[[",
        "[(",
        "@{ shape:",
        "-.->",
        "==>",
        "--o",
        "--x",
        "<-->",
        "~~~",
        "subgraph",
        "direction",
        "classDef",
        ":::",
        "style ",
        "linkStyle",
        "click ",
        "flowchart RL",
        "flowchart BT",
        "flowchart LR",
        "flowchart TB",
    ] {
        assert!(all.contains(needle), "o showcase perdeu `{needle}`");
    }
    // sequence: tudo o que o merman parseia.
    for needle in [
        "autonumber",
        "actor ",
        "box ",
        "activate ",
        "deactivate ",
        "loop ",
        "alt ",
        "else ",
        "opt ",
        "par ",
        " and ",
        "critical ",
        "option ",
        "break ",
        "rect rgb",
        "Note left of",
        "Note right of",
        "Note over",
        "create participant",
        "destroy ",
        "->>+",
        "-->>-",
        "-)",
        "--)",
        "-x",
    ] {
        assert!(all.contains(needle), "o showcase perdeu `{needle}`");
    }
    // class, state, er e os outros.
    for needle in [
        "<<interface>>",
        "namespace ",
        "~K, V~",
        "<|--",
        "*--",
        "o--",
        "..|>",
        "cssClass",
        "<<choice>>",
        "<<fork>>",
        "<<join>>",
        "note right of",
        "PK",
        "FK",
        "UK",
        "||--o{",
        "}o--o{",
        "todayMarker",
        "milestone",
        "cherry-pick",
        "tag:",
        "type: REVERSE",
        "type: HIGHLIGHT",
        "section ",
        "::icon(",
        "packet-beta",
        "timeline",
        "treeView-beta",
        "xychart-beta horizontal",
        "line [",
        "bar [",
        "kanban",
        "journey",
    ] {
        assert!(all.contains(needle), "o showcase perdeu `{needle}`");
    }
    // O 50+ nos: o bloco com mais definicoes de no por classe.
    let big = showcase_blocks()
        .into_iter()
        .filter(|b| b.family == "flowchart")
        .map(|b| b.source.matches(":::").count())
        .max()
        .unwrap_or(0);
    assert!(
        big >= 50,
        "o maior flowchart tem {big} nos com classe, queria 50 ou mais"
    );
}

#[test]
fn every_showcase_diagram_renders() {
    let mut failures = Vec::new();
    for block in drawn_blocks() {
        match render_with_notice(&block.source, &opts()) {
            Ok(r) => {
                let ctx = format!("{} ({})", block.title, block.family);
                assert!(!r.lines.is_empty(), "{ctx}: sem linhas");
                assert!(
                    r.lines.iter().any(|l| !l.trim().is_empty()),
                    "{ctx}: so linhas em branco"
                );
                assert!(
                    !r.lines.first().is_some_and(|l| l.trim().is_empty())
                        && !r.lines.last().is_some_and(|l| l.trim().is_empty()),
                    "{ctx}: linha em branco sobrando no comeco ou no fim"
                );
                for line in &r.lines {
                    assert!(
                        !line.chars().any(|c| c.is_control() || c == '\u{fffd}'),
                        "{ctx}: lixo na linha {line:?}"
                    );
                }
            }
            Err(err) => failures.push(format!("{} ({}): {err}", block.title, block.family)),
        }
    }
    assert!(
        failures.is_empty(),
        "blocos do showcase que degradam:\n{}",
        failures.join("\n")
    );
}

#[test]
fn only_the_ilza_diagrams_need_the_simplified_layout() {
    for block in drawn_blocks() {
        let r = rendered(&block.source, &opts());
        let ctx = format!("{} ({})", block.title, block.family);
        assert_eq!(r.notice.is_some(), is_ilza(&block), "{ctx}: {:?}", r.notice);
    }
    assert_eq!(drawn_blocks().iter().filter(|b| is_ilza(b)).count(), 2);
}

#[test]
fn the_ilza_blocks_are_the_readme_verbatim() {
    let ilza: Vec<_> = showcase_blocks().into_iter().filter(is_ilza).collect();
    assert_eq!(ilza.len(), 2, "os dois diagramas do README do ILZA");
    assert_eq!(ilza[0].source.trim_end(), ILZA_ARCHITECTURE.trim_end());
    assert_eq!(ilza[1].source.trim_end(), ILZA_MODULES.trim_end());
}

#[test]
fn the_ilza_diagrams_render_at_every_width_and_charset() {
    for fixture in [ILZA_ARCHITECTURE, ILZA_MODULES] {
        for width in [20, 40, 80, 120, 1000] {
            for charset in [Charset::Unicode, Charset::Ascii] {
                let o = RenderOptions {
                    width,
                    charset,
                    ..RenderOptions::default()
                };
                let r = rendered(fixture, &o);
                assert!(
                    r.notice
                        .as_deref()
                        .is_some_and(|n| n.contains("subgraph boxes removed")),
                    "largura {width}: {:?}",
                    r.notice
                );
            }
        }
    }
    // Nenhum no se perde: o que o autor escreveu esta no desenho.
    let arch = rendered(ILZA_ARCHITECTURE, &opts()).lines.join("\n");
    for label in [
        "Frontend",
        "TriageEngine",
        "OpenAI API",
        "BCrypt Hasher",
        "FastAPI",
        "Upload PDF",
    ] {
        assert!(
            arch.contains(label),
            "{label} sumiu do desenho da arquitetura"
        );
    }
    let modules = rendered(ILZA_MODULES, &opts()).lines.join("\n");
    for label in [
        "app.py",
        "Domain Exceptions",
        "TriageWorkflow",
        "Factory DI",
    ] {
        assert!(
            modules.contains(label),
            "{label} sumiu do desenho dos modulos"
        );
    }
}

#[test]
fn the_showcase_pie_is_unsupported_and_names_the_type() {
    let pies: Vec<_> = showcase_blocks()
        .into_iter()
        .filter(is_expected_to_degrade)
        .collect();
    assert_eq!(pies.len(), 1);
    let err = err_of(&pies[0].source, &opts());
    assert!(matches!(err, RenderError::Unsupported(_)), "{err:?}");
    assert!(err.to_string().contains("pie"), "{err}");
}

#[test]
fn every_showcase_diagram_renders_in_ascii_without_non_ascii_bytes() {
    for block in drawn_blocks() {
        let ctx = format!("{} ({})", block.title, block.family);
        let r = rendered(&block.source, &ascii_opts());
        for line in &r.lines {
            // O texto do autor tem acento, emoji e CJK, e o merman nao o troca. Todo caractere
            // fora do ASCII que sobra no desenho tem que ter vindo dele: a moldura, as setas e
            // as linhas das familias de texto estruturado saem em ASCII puro.
            if let Some(c) = line
                .chars()
                .find(|c| !c.is_ascii() && !block.source.contains(*c))
            {
                panic!(
                    "{ctx}: {c:?} (U+{:04X}) no charset ascii nao veio do fonte: {line:?}",
                    c as u32
                );
            }
        }
    }
}

#[test]
fn every_showcase_render_is_deterministic() {
    for block in drawn_blocks() {
        let a = rendered(&block.source, &opts());
        let b = rendered(&block.source, &opts());
        assert_eq!(a, b, "{} ({})", block.title, block.family);
    }
}

#[test]
fn showcase_text_without_color_escapes_is_identical_to_the_plain_render() {
    // A cor nao muda uma celula do layout: sem os escapes, cada bloco do showcase sai igual ao
    // modo Plain (as mesmas linhas e o mesmo aviso de simplificacao).
    let mut with_escapes = 0;
    for block in drawn_blocks() {
        let ctx = format!("{} ({})", block.title, block.family);
        let plain = rendered(&block.source, &opts());
        let colored = rendered(&block.source, &color_opts());
        let stripped: Vec<String> = colored.lines.iter().map(|l| strip_sgr(l)).collect();
        assert_eq!(stripped.len(), plain.lines.len(), "{ctx}: numero de linhas");
        for (row, (got, want)) in stripped.iter().zip(&plain.lines).enumerate() {
            // Espaco no fim da linha e invisivel, e o merman o poe em algumas familias (class, er)
            // so no modo colorido: o que se compara e o que aparece.
            assert_eq!(
                got.trim_end(),
                want.trim_end(),
                "{ctx}: a linha {row} mudou com a cor\n  cor:   {:?}\n  plain: {want:?}",
                colored.lines[row]
            );
        }
        assert_eq!(colored.notice, plain.notice, "{ctx}");

        let raw = colored.lines.join("\n");
        for theme in THEME_DEFAULTS {
            assert!(!raw.contains(theme), "{ctx}: vazou a cor do tema {theme}");
        }
        // So estas familias honram o estilo na cor (medido): no class, o `classDef` e o `style`
        // do showcase passam pelo parser e nao viram cor.
        let styled = matches!(block.family.as_str(), "flowchart" | "state" | "sequence")
            && (block.source.contains("classDef ")
                || block.source.contains("style ")
                || block.source.contains("rgb("));
        if styled {
            assert!(
                raw.contains('\u{1b}'),
                "{ctx}: o diagrama tem estilo e a saida nao tem cor"
            );
            with_escapes += 1;
        }
    }
    assert!(
        with_escapes >= 5,
        "so {with_escapes} blocos estilizados do showcase sairam coloridos"
    );
}

#[test]
fn showcase_styling_does_not_change_the_drawing() {
    // `classDef`, `style`, `linkStyle` e `class` nao viram cor na arte de texto, mas tambem nao
    // podem mudar o desenho nem derrubar o render: o diagrama sem eles sai igual.
    let styled = "flowchart LR\n  classDef k fill:#f00,stroke:#00f\n  A[Um]:::k --> B[Dois]\n  \
                  style B fill:#0f0\n  linkStyle 0 stroke:#f0f,color:red\n  class A k";
    let plain = "flowchart LR\n  A[Um] --> B[Dois]";
    assert_eq!(
        render(styled, &opts()).unwrap(),
        render(plain, &opts()).unwrap()
    );

    // `rect rgb(...)` e `box rgb(...)` do sequence: o desenho sai, com tudo o que tinha.
    let styled =
        "sequenceDiagram\n  box rgb(1,2,3) Grupo\n    participant A\n    participant B\n  end\n  \
                  rect rgb(200,0,0)\n    A->>B: oi\n  end";
    let text = render(styled, &opts()).unwrap().join("\n");
    for needle in ["A", "B", "oi"] {
        assert!(text.contains(needle), "{needle}:\n{text}");
    }
}

// --- entidades HTML nos rotulos (V11) ------------------------------------------------------

/// Toda linha com o mesmo numero de colunas (so ha ASCII e desenho de caixa nestes casos, todos de
/// uma celula): o merman completa as linhas ate a largura do desenho, e a decodificacao nao
/// pode deixar nenhuma mais curta.
fn assert_rectangular(name: &str, lines: &[String]) {
    let widest = widest(lines);
    for (row, line) in lines.iter().enumerate() {
        assert_eq!(
            line.chars().count(),
            widest,
            "{name}: a linha {row} perdeu largura:\n{}",
            lines.join("\n")
        );
    }
}

#[test]
fn flowchart_entities_are_decoded_and_the_boxes_stay_aligned() {
    let src = "flowchart LR\n  A[\"a &lt; b\"] --> B[\"3 &lt;&lt; 4\"]\n  B -->|\"x &lt; y\"| C[\"p &amp; q &gt; r\"]\n  C --> D[\"cmp #lt; e\"]";
    for charset in [Charset::Unicode, Charset::Ascii] {
        let lines = render(src, &RenderOptions { charset, ..opts() }).unwrap();
        let text = lines.join("\n");
        for needle in ["a < b", "3 << 4", "x < y", "p & q > r", "cmp < e"] {
            assert!(
                text.contains(needle),
                "{charset:?}: faltou {needle:?}:\n{text}"
            );
        }
        for entity in ["&lt;", "&gt;", "&amp;"] {
            assert!(
                !text.contains(entity),
                "{charset:?}: sobrou {entity}:\n{text}"
            );
        }
        assert_rectangular(&format!("flowchart {charset:?}"), &lines);
    }
}

#[test]
fn state_entities_are_decoded_too() {
    let src = "stateDiagram-v2\n  state \"Idle &lt;wait&gt;\" as Idle\n  [*] --> Idle\n  Idle --> Busy\n  Busy --> [*]";
    let lines = render(src, &opts()).unwrap();
    let text = lines.join("\n");
    assert!(text.contains("Idle <wait>"), "{text}");
    assert!(!text.contains("&lt;") && !text.contains("&gt;"), "{text}");
    assert_rectangular("state", &lines);
}

#[test]
fn entities_in_cjk_and_emoji_labels_do_not_misalign_the_right_border() {
    let src = "flowchart LR\n  A[\"你好 &lt; 世界\"] --> B[\"🚀 &amp; ありがとう\"]";
    let lines = render(src, &opts()).unwrap();
    let text = lines.join("\n");
    assert!(text.contains("你好 < 世界"), "{text}");
    assert!(text.contains("🚀 & ありがとう"), "{text}");
    // Largura em celulas: o `│` da direita de cada caixa fica na mesma coluna em todas as
    // linhas com texto (a coluna e a do `┐` da borda de cima).
    let cells = |s: &str| -> usize {
        s.chars()
            .map(|c| match c as u32 {
                0x1100..=0x115f | 0x2e80..=0xa4cf | 0xac00..=0xd7a3 | 0xff00..=0xff60 => 2,
                0x1f300..=0x1faff => 2,
                _ => 1,
            })
            .sum()
    };
    let top = lines.iter().find(|l| l.starts_with('┌')).unwrap();
    for line in lines
        .iter()
        .filter(|l| l.contains("你好") || l.contains("🚀"))
    {
        assert_eq!(cells(line), cells(top), "{line:?} vs {top:?}");
        // O fim visivel da linha (a ultima borda) cai na mesma coluna do `┐` de cima.
        assert_eq!(
            cells(line.trim_end()),
            cells(top.trim_end()),
            "{line:?} vs {top:?}"
        );
    }
}

#[test]
fn double_encoded_ampersand_is_a_known_limitation() {
    // O merman ja decodifica `&amp;lt;` uma vez, e entrega `&lt;`, que a limpeza nao distingue
    // de um `&lt;` que ele deixou literal: o texto sai `x < y`, nao `x &lt; y` (V11).
    let lines = render("flowchart LR\n  A[\"x &amp;lt; y\"]", &opts()).unwrap();
    assert!(lines.join("\n").contains("x < y"), "{}", lines.join("\n"));
}

#[test]
fn numeric_apostrophe_entity_is_a_known_limitation() {
    // O merman consome o `#39;` de `&#39;` como codigo de entidade do Mermaid e deixa o `&`.
    // Nao ha o que decodificar na saida; o teste fixa o comportamento para a V11 (use `#39;`).
    let text = render("flowchart LR\n  A[\"it&#39;s\"]", &opts())
        .unwrap()
        .join("\n");
    assert!(text.contains("it&'s"), "{text}");
    let ok = render("flowchart LR\n  A[\"it#39;s\"]", &opts())
        .unwrap()
        .join("\n");
    assert!(ok.contains("it's"), "{ok}");
}

// --- cor (TrueColor) -----------------------------------------------------------------------

fn color_opts() -> RenderOptions {
    RenderOptions {
        color: true,
        ..opts()
    }
}

/// As linhas sem o espaco do fim (invisivel; ver `showcase_text_without_color_escapes...`).
fn trim_rows(lines: &[String]) -> Vec<String> {
    lines.iter().map(|l| l.trim_end().to_string()).collect()
}

/// Tira os escapes SGR (`ESC [ ... m`) de uma linha.
fn strip_sgr(line: &str) -> String {
    let mut out = String::new();
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            for n in chars.by_ref() {
                if ('\u{40}'..='\u{7e}').contains(&n) {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

const STYLED_FLOWCHART: &str = "flowchart LR\n  A[Start] --> B{Ok?}\n  B -->|yes| C[Done]\n  B -->|no| D[Retry]\n  classDef good fill:#e3f2fd,stroke:#1565c0,color:#0d47a1\n  classDef bad fill:#fce4ec,stroke:#c62828\n  class A,C good\n  class D bad\n  style B fill:#fff3e0,stroke:#e65100\n  linkStyle 0 stroke:#ff0000";

const STYLED_SEQUENCE: &str = "sequenceDiagram\n  box rgb(200,220,255) Frontend\n    participant U as User\n    participant W as Web\n  end\n  rect rgb(255,230,200)\n    U->>W: click\n    W-->>U: ok\n  end";

/// As cores do tema claro do merman, que nenhum diagrama pediu e que nao podem sair.
const THEME_DEFAULTS: &[&str] = &[
    "39;39;42",    // texto
    "161;161;170", // borda de no
    "113;113;122", // linha de aresta
    "82;82;91",    // seta
    "124;58;237",  // titulo de secao
    "29;78;216",   // titulo
];

#[test]
fn color_is_off_by_default_and_plain_output_has_no_escapes() {
    assert!(!RenderOptions::default().color);
    for (family, src) in MINIMAL.iter().chain([("styled", STYLED_FLOWCHART)].iter()) {
        let lines = render(src, &opts()).unwrap();
        assert!(
            lines.iter().all(|l| !l.contains('\u{1b}')),
            "{family}: escape no modo Plain"
        );
    }
}

#[test]
fn a_diagram_without_styling_has_no_color_at_all() {
    // Sem classDef/style, nada a pintar: o tema do merman nao vaza para o preview.
    for src in [
        "flowchart LR\n  A[Start] --> B[End]",
        "sequenceDiagram\n  Alice->>John: Hello\n  John-->>Alice: Hi",
        "classDiagram\n  class Animal\n  class Duck\n  Animal <|-- Duck",
        "stateDiagram-v2\n  [*] --> A\n  A --> [*]",
        "erDiagram\n  CUSTOMER ||--o{ ORDER : places",
        "mindmap\n  root((Root))\n    A\n    B",
    ] {
        let lines = render(src, &color_opts()).unwrap();
        let escapes: Vec<&String> = lines.iter().filter(|l| l.contains('\u{1b}')).collect();
        assert!(escapes.is_empty(), "{src}\n{escapes:?}");
    }
}

#[test]
fn authored_colors_come_out_as_truecolor_and_theme_colors_do_not() {
    let lines = render(STYLED_FLOWCHART, &color_opts()).unwrap();
    let raw = lines.join("\n");
    for authored in [
        "38;2;21;101;192",  // stroke da classe good
        "48;2;227;242;253", // fill da classe good
        "38;2;13;71;161",   // color da classe good
        "38;2;198;40;40",   // stroke da classe bad
        "38;2;230;81;0",    // style do no B
        "38;2;255;0;0",     // linkStyle 0
    ] {
        assert!(raw.contains(authored), "faltou {authored}:\n{raw}");
    }
    for theme in THEME_DEFAULTS {
        assert!(!raw.contains(theme), "vazou a cor do tema {theme}:\n{raw}");
    }
    assert!(!raw.contains("38;2;1;2;3"), "sobrou a cor-sentinela");
}

#[test]
fn box_and_rect_colors_of_a_sequence_diagram_come_out() {
    let raw = render(STYLED_SEQUENCE, &color_opts()).unwrap().join("\n");
    assert!(raw.contains("48;2;200;220;255"), "box rgb:\n{raw}");
    assert!(raw.contains("48;2;255;230;200"), "rect rgb:\n{raw}");
    for theme in THEME_DEFAULTS {
        assert!(!raw.contains(theme), "vazou a cor do tema {theme}");
    }
}

#[test]
fn the_text_without_escapes_is_identical_to_the_plain_render() {
    // O ponto da etapa 4: a cor nao muda o layout nem uma celula. Sem os escapes, a saida e a
    // do modo Plain, linha por linha, para todos os tipos e para os diagramas reais do ILZA.
    let mut cases: Vec<(String, String)> = MINIMAL
        .iter()
        .map(|(family, src)| ((*family).to_string(), (*src).to_string()))
        .collect();
    cases.push(("styled flowchart".into(), STYLED_FLOWCHART.into()));
    cases.push(("styled sequence".into(), STYLED_SEQUENCE.into()));
    cases.push(("ilza architecture".into(), ILZA_ARCHITECTURE.into()));
    cases.push(("ilza modules".into(), ILZA_MODULES.into()));
    cases.push((
        "entities".into(),
        "flowchart LR\n  A[\"a &lt; b\"] --> B[\"x &amp; y\"]\n  classDef c fill:#eee,stroke:#333\n  class A,B c".into(),
    ));
    for width in [40, 120] {
        for (name, src) in &cases {
            let plain = render_with_notice(src, &RenderOptions { width, ..opts() })
                .unwrap_or_else(|e| panic!("{name}: {e}"));
            let colored = render_with_notice(
                src,
                &RenderOptions {
                    width,
                    ..color_opts()
                },
            )
            .unwrap_or_else(|e| panic!("{name} (cor): {e}"));
            let stripped: Vec<String> = colored.lines.iter().map(|l| strip_sgr(l)).collect();
            assert_eq!(
                trim_rows(&stripped),
                trim_rows(&plain.lines),
                "{name}, largura {width}"
            );
            assert_eq!(colored.notice, plain.notice, "{name}");
        }
    }
}

#[test]
fn color_render_is_deterministic_and_keeps_the_fallback() {
    let a = render_with_notice(ILZA_MODULES, &color_opts()).unwrap();
    let b = render_with_notice(ILZA_MODULES, &color_opts()).unwrap();
    assert_eq!(a, b);
    assert!(a.notice.is_some(), "o ILZA sai simplificado");
    // O ILZA tem classDef: a cor autoral sobrevive ao achatamento.
    assert!(a.lines.join("\n").contains("38;2;230;81;0"));
}

#[test]
fn entities_are_decoded_inside_colored_lines_without_losing_width() {
    let src = "flowchart LR\n  A[\"a &lt; b\"] --> B[\"3 &lt;&lt; 4\"]\n  classDef c fill:#e3f2fd,stroke:#1565c0,color:#0d47a1\n  class A,B c";
    let lines = render(src, &color_opts()).unwrap();
    let plain: Vec<String> = lines.iter().map(|l| strip_sgr(l)).collect();
    let text = plain.join("\n");
    assert!(text.contains("a < b") && text.contains("3 << 4"), "{text}");
    assert!(!text.contains("&lt;"), "{text}");
    assert_rectangular("entidades com cor", &plain);
    assert!(lines.join("\n").contains("48;2;227;242;253"));
}

#[test]
fn ascii_charset_with_color_only_has_ascii_bytes() {
    let lines = render(
        STYLED_FLOWCHART,
        &RenderOptions {
            charset: Charset::Ascii,
            ..color_opts()
        },
    )
    .unwrap();
    assert!(lines.iter().all(|l| l.is_ascii()), "{lines:?}");
    assert!(lines.join("\n").contains("38;2;21;101;192"));
}

#[test]
fn chart_series_keep_their_data_colors() {
    let src = "xychart-beta\n  x-axis [a, b, c]\n  y-axis \"Y\" 0 --> 10\n  bar [3, 7, 5]\n  line [2, 6, 4]";
    let raw = render(src, &color_opts()).unwrap().join("\n");
    assert!(raw.contains('\u{1b}'), "o xychart nao saiu colorido");
    for theme in THEME_DEFAULTS {
        assert!(!raw.contains(theme), "vazou a cor do tema {theme}");
    }
}

// --- depuracao: `make dump FILE=x.mmd` -----------------------------------------------------

/// Desenha o arquivo de `DECKLE_DUMP` e imprime o resultado, para olhar a arte. Largura em
/// `DECKLE_DUMP_WIDTH` (padrao 100); `DECKLE_DUMP_ASCII=1` troca o charset.
#[test]
#[ignore = "ferramenta de depuracao: rode `make dump FILE=caminho.mmd`"]
fn dump_file() {
    let path = std::env::var("DECKLE_DUMP").expect("defina DECKLE_DUMP=caminho.mmd");
    let src = std::fs::read_to_string(&path).expect("ler o arquivo");
    let width = std::env::var("DECKLE_DUMP_WIDTH")
        .ok()
        .and_then(|w| w.parse().ok())
        .unwrap_or(100);
    let charset = if std::env::var("DECKLE_DUMP_ASCII").is_ok_and(|v| v == "1") {
        Charset::Ascii
    } else {
        Charset::Unicode
    };
    let color = std::env::var("DECKLE_DUMP_COLOR").is_ok_and(|v| v == "1");
    let started = Instant::now();
    let opts = RenderOptions {
        width,
        charset,
        color,
        ..RenderOptions::default()
    };
    match render_with_notice(&src, &opts) {
        Ok(rendered) => {
            // Com cor, os escapes saem como `\e` visivel: o terminal do dump nao os interpreta.
            println!("{}", rendered.lines.join("\n").replace('\u{1b}', "\\e"));
            println!(
                "-- ok: {} linhas, {} colunas, notice={:?}, {:?}",
                rendered.lines.len(),
                widest(&rendered.lines),
                rendered.notice,
                started.elapsed()
            );
        }
        Err(err) => println!("-- ERR: {err}"),
    }
}

// --- benchmark (V5): `make bench` ----------------------------------------------------------

/// Flowchart "medio": 6 arestas, na ordem de grandeza do caso medido em V5.
const MEDIUM_FLOWCHART: &str = "flowchart TD\n  A-->B\n  A-->C\n  B-->D\n  C-->D\n  D-->E\n  E-->F";

/// Flowchart "grande e fundo": corrente de 41 nos (40 arestas) mais 8 arestas que pulam
/// 3 nos = 48 arestas. Nao e o grafo exato de V5 (nao foi guardado), mas tem a mesma
/// contagem de arestas e a mesma ordem de grandeza de linhas de saida (~400).
fn deep_flowchart() -> String {
    let mut src = String::from("flowchart TD\n");
    for i in 0..40 {
        writeln!(src, "  N{i} --> N{}", i + 1).unwrap();
    }
    for i in 0..8 {
        writeln!(src, "  N{} --> N{}", i * 5, i * 5 + 3).unwrap();
    }
    src
}

/// Flowchart "grande e largo": 5 camadas de 6 nos, cada no liga a 2 da camada seguinte =
/// 48 arestas. Mesma contagem de arestas, forma oposta: poucas linhas, muito cruzamento.
fn wide_flowchart() -> String {
    let mut src = String::from("flowchart TD\n");
    for layer in 0..4 {
        for i in 0..6 {
            for d in 0..2 {
                writeln!(src, "  L{layer}N{i} --> L{}N{}", layer + 1, (i + d) % 6).unwrap();
            }
        }
    }
    src
}

fn time_render(name: &str, src: &str, runs: usize) -> Duration {
    let o = RenderOptions {
        width: 10_000,
        ..RenderOptions::default()
    };
    let warm = render(src, &o).expect("benchmark input must render");
    let mut samples: Vec<Duration> = (0..runs)
        .map(|_| {
            let t = Instant::now();
            let lines = render(src, &o).unwrap();
            let elapsed = t.elapsed();
            assert_eq!(lines.len(), warm.len());
            elapsed
        })
        .collect();
    samples.sort();
    let median = samples[samples.len() / 2];
    println!(
        "bench {name}: {} linhas, {} arestas, min {:?}, mediana {:?}, max {:?} ({runs} execucoes)",
        warm.len(),
        src.matches("-->").count(),
        samples[0],
        median,
        samples[samples.len() - 1],
    );
    median
}

#[test]
fn large_flowchart_fixtures_have_48_edges_and_pass_the_guard() {
    for (name, src) in [("deep", deep_flowchart()), ("wide", wide_flowchart())] {
        assert_eq!(src.matches("-->").count(), 48, "{name}");
        assert!(
            src.lines().count() < DEFAULT_MAX_SRC_LINES,
            "{name}: tem que passar na guarda"
        );
        assert!(render(&src, &opts()).is_ok(), "{name}");
    }
}

#[test]
#[ignore = "benchmark: rode `make bench` (usa --release)"]
fn bench_flowchart() {
    time_render("flowchart medio", MEDIUM_FLOWCHART, 50);
    time_render("flowchart grande e fundo", &deep_flowchart(), 15);
    time_render("flowchart grande e largo", &wide_flowchart(), 15);
}
