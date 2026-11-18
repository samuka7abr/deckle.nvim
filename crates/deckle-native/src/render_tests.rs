//! Testes da logica pura. Rodam com `cargo test`, sem Lua e sem Neovim.

use std::fmt::Write as _;
use std::time::{Duration, Instant};

use crate::render::{
    guarded, render, render_ex, supported_types, Charset, RenderError, RenderOptions, Simplified,
    DEFAULT_MAX_SRC_LINES,
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
    (
        "swimlane",
        "swimlane-beta LR\n  subgraph Dev\n    A[Code] --> B[Test]\n  end\n  subgraph Ops\n    C[Deploy]\n  end\n  B --> C",
    ),
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

// --- gate 1: os 15 tipos -------------------------------------------------------------------

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
    assert_eq!(supported.len(), 15);
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

// --- fallback de achatamento (V11) ---------------------------------------------------------

/// Os diagramas reais do usuario (ILZA). Nenhuma versao do merman os roteia: erro
/// `routes crossing reserved graph geometry`.
const ILZA_ARCHITECTURE: &str = include_str!("../tests/fixtures/ilza_architecture.mmd");
const ILZA_MODULES: &str = include_str!("../tests/fixtures/ilza_modules.mmd");

/// Menor flowchart que o merman 0.8.0 nao roteia (`ddmin` da investigacao V11): uma aresta que
/// sai de um subgraph e entra no PRIMEIRO no de outro.
const SUBGRAPH_EDGE_FAILS: &str = "flowchart TB\n  subgraph API\n    h1[h1]\n  end\n  subgraph Temporal\n    t1[t1]\n    t2[t2]\n  end\n  API --> t1";

/// A mesma forma, com a aresta no segundo no: o merman roteia, e o fallback nao pode rodar.
const SUBGRAPH_EDGE_WORKS: &str = "flowchart TB\n  subgraph API\n    h1[h1]\n  end\n  subgraph Temporal\n    t1[t1]\n    t2[t2]\n  end\n  API --> t2";

#[test]
fn the_merman_really_fails_on_the_minimal_subgraph_edge() {
    // Guarda do pino: se o merman passar a rotear este caso, o fallback nao tem mais o que
    // consertar nele e este teste avisa, para a investigacao V11 ser refeita.
    let err = draw_without_fallback(SUBGRAPH_EDGE_FAILS);
    assert!(
        err.to_string()
            .contains("routes crossing reserved graph geometry"),
        "{err}"
    );
}

fn draw_without_fallback(src: &str) -> RenderError {
    // Renderiza o mesmo diagrama sem o fallback: o texto original pelo `render_model`.
    match crate::render::render_unflattened(src, &opts()) {
        Ok(lines) => panic!("era para falhar, saiu:\n{}", lines.join("\n")),
        Err(err) => err,
    }
}

#[test]
fn minimal_subgraph_failure_renders_flattened_and_says_so() {
    let rendered = render_ex(SUBGRAPH_EDGE_FAILS, &opts()).expect("o fallback tem que desenhar");
    assert_eq!(rendered.simplified, Some(Simplified::Subgraphs));
    assert!(
        rendered
            .cause
            .as_deref()
            .is_some_and(|c| c.contains("routes crossing reserved graph geometry")),
        "{:?}",
        rendered.cause
    );
    let text = rendered.lines.join("\n");
    for needle in ["API", "h1", "t1", "t2"] {
        assert!(text.contains(needle), "faltou {needle}:\n{text}");
    }
    // `render` devolve as mesmas linhas, so que sem a informacao.
    assert_eq!(
        render(SUBGRAPH_EDGE_FAILS, &opts()).unwrap(),
        rendered.lines
    );
}

#[test]
fn both_ilza_diagrams_render_through_the_fallback() {
    for (name, src) in [
        ("architecture", ILZA_ARCHITECTURE),
        ("modules", ILZA_MODULES),
    ] {
        let rendered = render_ex(src, &opts()).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(rendered.simplified, Some(Simplified::Subgraphs), "{name}");
        assert!(
            rendered.lines.len() > 20,
            "{name}: {} linhas",
            rendered.lines.len()
        );
        // Os nos continuam la, com os rotulos.
        let text = rendered.lines.join("\n");
        let probes: &[&str] = if name == "architecture" {
            &["Frontend", "TriageEngine", "PostgreSQL 16"]
        } else {
            &["TriageAgent", "Settings", "engine.py"]
        };
        for needle in probes {
            assert!(text.contains(needle), "{name}: faltou {needle}");
        }
        // O desenho e deterministico.
        assert_eq!(render_ex(src, &opts()).unwrap(), rendered, "{name}");
    }
}

#[test]
fn ilza_architecture_keeps_the_subgraph_endpoints_as_nodes() {
    // `FE -->|"HTTP/REST"| API` e `API --> ENGINE` citam o subgraph `API`: ele vira um no com o
    // titulo, em vez de a aresta sumir.
    let text = render(ILZA_ARCHITECTURE, &opts()).unwrap().join("\n");
    assert!(text.contains("FastAPI"), "{text}");
    assert!(text.contains("HTTP/REST"), "{text}");
    // `Cliente` e `Modulos da Aplicacao` nao sao ponta de aresta nenhuma: somem com a caixa.
    assert!(!text.contains("Cliente"), "{text}");
}

#[test]
fn fallback_does_not_run_when_the_first_render_works() {
    let rendered = render_ex(SUBGRAPH_EDGE_WORKS, &opts()).unwrap();
    assert_eq!(rendered.simplified, None);
    assert_eq!(rendered.cause, None);
    // Fiel: as caixas dos subgraphs estao no desenho (o titulo `Temporal` so existe nelas).
    let text = rendered.lines.join("\n");
    assert!(text.contains("Temporal"), "{text}");

    // Diagramas sem subgraph nunca simplificam.
    for (_, src) in MINIMAL {
        assert_eq!(render_ex(src, &opts()).unwrap().simplified, None, "{src}");
    }
}

#[test]
fn fallback_ignores_errors_that_are_not_routing_failures() {
    // Sintaxe invalida com subgraph: continua erro de parse, sem tentativa de achatar.
    let err = err_of("flowchart TD\n  subgraph S\n    A -->\n  end", &opts());
    assert!(matches!(err, RenderError::Parse(_)), "{err:?}");

    // Forma que o renderer nao cobre, dentro de subgraph: o erro e o da forma, nao o do layout.
    let src = "flowchart TD\n  subgraph S\n    A@{ shape: cloud }\n  end";
    let err = err_of(src, &opts());
    assert!(
        err.to_string().contains("shape"),
        "o erro deveria ser o da forma: {err}"
    );
}

#[test]
fn routing_failure_classifier_only_matches_routing_messages() {
    use crate::render::is_routing_failure;
    for msg in [
        "unsupported diagram: ASCII rendering does not support `routes crossing reserved graph geometry` for `flowchart` yet",
        "mermaid render failed: unroutable graph edges",
    ] {
        let err = if msg.starts_with("unsupported") {
            RenderError::Unsupported(msg.into())
        } else {
            RenderError::Render(msg.into())
        };
        assert!(is_routing_failure(&err), "{msg}");
    }
    assert!(!is_routing_failure(&RenderError::Parse(
        "routes crossing reserved graph geometry".into()
    )));
    assert!(!is_routing_failure(&RenderError::Unsupported(
        "diagram type `pie`".into()
    )));
    assert!(!is_routing_failure(&RenderError::EmptySource));
}

#[test]
fn nested_composite_state_renders_flattened() {
    // O caso medido na investigacao: composto dentro de composto, com transicao. O merman
    // erra o roteamento; o fallback tira as chaves.
    let src = "stateDiagram-v2\n  state Fora {\n    state Dentro {\n      [*] --> X\n    }\n    [*] --> Dentro\n  }";
    let rendered = render_ex(src, &opts()).expect("o fallback tem que desenhar");
    assert_eq!(rendered.simplified, Some(Simplified::CompositeStates));
    assert!(rendered.lines.join("\n").contains('X'));
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
    let started = Instant::now();
    let opts = RenderOptions {
        width,
        charset,
        ..RenderOptions::default()
    };
    match render_ex(&src, &opts) {
        Ok(rendered) => {
            println!("{}", rendered.lines.join("\n"));
            println!(
                "-- ok: {} linhas, {} colunas, simplified={:?}, {:?}",
                rendered.lines.len(),
                widest(&rendered.lines),
                rendered.simplified,
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
