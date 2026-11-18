//! Fallback de achatamento (etapa 2 da branch `fix/mermaid-showcase`).
//!
//! O `merman-ascii` nao consegue rotear uma aresta que cruza a borda de um `subgraph` quando
//! sobram poucos candidatos de rota, e responde `routes crossing reserved graph geometry`
//! (V11). Nenhuma opcao publica contorna isso, e todas as versoes testadas falham igual nos
//! diagramas reais do usuario. O que contorna e **desenhar sem as caixas dos subgraphs**: o
//! mesmo grafo, com os mesmos nos e arestas, so que plano.
//!
//! Este modulo e Rust puro e textual: `&str` entra, `String` sai. Nao conhece o merman, o Lua
//! nem o Neovim (ADR-0001), nunca entra em panic (so fatia `str` por limites que o proprio
//! `str` devolveu) e devolve `None` quando nao ha o que achatar, para o chamador manter o erro
//! original.
//!
//! # Flowchart
//!
//! Somem as linhas `subgraph ...`, o `end` que fecha cada uma e o `direction ...` de dentro
//! delas. Nos e arestas ficam como estao. Uma aresta cujo ponto e o **id de um subgraph**
//! (`API -->|x| ENGINE`) nao pode apontar para uma caixa que deixou de existir, e descartar a
//! aresta deslocaria os indices do `linkStyle`. Por isso o subgraph citado em aresta vira um
//! no comum, com o mesmo id e o mesmo titulo (`API["⚡ FastAPI"]`): a aresta continua inteira e
//! o desenho mostra um bloco com o nome do grupo. Subgraph que nenhuma aresta cita some por
//! inteiro, e os `style`, `class` e `click` que o nomeavam saem junto (nao ha mais no a
//! estilizar).
//!
//! # State
//!
//! Estado composto (`state X { ... }`) perde as chaves, e a linha `--` de concorrencia e o
//! `direction` de dentro somem. O `state X` do composto so fica se alguma transicao o cita.
//! Os `[*]` de dentro e de fora passam a ser o mesmo: e uma simplificacao, e o resultado
//! avisa que houve.

use std::collections::HashSet;

use crate::render::Simplified;

/// Achata `src`. `None` quando o diagrama nao e flowchart nem state, ou nao tem subgraph (ou
/// estado composto) nenhum: nesse caso o achatamento nao muda nada e nao ha o que tentar.
pub(crate) fn flatten(src: &str) -> Option<(String, Simplified)> {
    let lines: Vec<&str> = src.lines().collect();
    match family(&lines)? {
        Family::Flowchart => flatten_flowchart(&lines).map(|flat| (flat, Simplified::Subgraphs)),
        Family::State => flatten_state(&lines).map(|flat| (flat, Simplified::CompositeStates)),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Family {
    Flowchart,
    State,
}

/// A familia pelo cabecalho: primeira linha que nao e vazia, comentario, diretiva nem
/// front-matter.
fn family(lines: &[&str]) -> Option<Family> {
    let mut in_front_matter = false;
    let mut seen_first = false;
    for line in lines {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        if !seen_first && t == "---" {
            in_front_matter = true;
            seen_first = true;
            continue;
        }
        seen_first = true;
        if in_front_matter {
            if t == "---" {
                in_front_matter = false;
            }
            continue;
        }
        if t.starts_with("%%") {
            continue;
        }
        let word = t
            .split(|c: char| c.is_whitespace() || c == ';')
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        return match word.as_str() {
            "flowchart" | "flowchart-v2" | "graph" => Some(Family::Flowchart),
            "statediagram" | "statediagram-v2" => Some(Family::State),
            _ => None,
        };
    }
    None
}

// --- helpers de texto --------------------------------------------------------------------------

/// O que vem depois da palavra-chave `kw` no inicio de `t`, sem espacos nas pontas. `None` se
/// `t` nao comeca com a palavra inteira (`subgraphs` nao e `subgraph`).
fn keyword_rest<'a>(t: &'a str, kw: &str) -> Option<&'a str> {
    let rest = t.strip_prefix(kw)?;
    if rest.is_empty() || rest.starts_with(char::is_whitespace) {
        Some(rest.trim())
    } else {
        None
    }
}

fn indent_of(line: &str) -> &str {
    let body = line.trim_start();
    &line[..line.len() - body.len()]
}

fn is_direction(t: &str) -> bool {
    match keyword_rest(t, "direction") {
        Some(rest) => matches!(
            rest.trim_end_matches(';').trim(),
            "TB" | "TD" | "BT" | "LR" | "RL"
        ),
        None => false,
    }
}

fn is_id_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Troca por espaco o que e rotulo (texto entre aspas, entre `|...|` e dentro de colchetes,
/// parenteses e chaves), para sobrar so a estrutura da linha: ids e setas.
fn strip_labels(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut in_quote = false;
    let mut in_pipe = false;
    let mut depth = 0usize;
    for c in line.chars() {
        if in_quote {
            if c == '"' {
                in_quote = false;
            }
            out.push(' ');
        } else if c == '"' {
            in_quote = true;
            out.push(' ');
        } else if depth > 0 {
            match c {
                '[' | '(' | '{' => depth += 1,
                ']' | ')' | '}' => depth -= 1,
                _ => {}
            }
            out.push(' ');
        } else if in_pipe {
            if c == '|' {
                in_pipe = false;
            }
            out.push(' ');
        } else if c == '|' {
            in_pipe = true;
            out.push(' ');
        } else if matches!(c, '[' | '(' | '{') {
            depth += 1;
            out.push(' ');
        } else {
            out.push(c);
        }
    }
    out
}

/// `id` aparece em `text` como palavra inteira (sem letra, digito ou `_` colado).
fn contains_token(text: &str, id: &str) -> bool {
    if id.is_empty() {
        return false;
    }
    text.match_indices(id).any(|(at, _)| {
        let before = text[..at].chars().next_back();
        let after = text[at + id.len()..].chars().next();
        !before.is_some_and(is_id_char) && !after.is_some_and(is_id_char)
    })
}

fn has_arrow(stripped: &str) -> bool {
    ["--", "==", "-.", "~~~"]
        .iter()
        .any(|a| stripped.contains(a))
}

// --- flowchart ---------------------------------------------------------------------------------

enum Item<'a> {
    /// `subgraph id [titulo]`: o id (se tem forma de id) e o trecho `[titulo]` como esta.
    Sub {
        indent: &'a str,
        id: Option<String>,
        label: &'a str,
    },
    End,
    Direction,
    Line(&'a str),
}

/// Separa `id` e `[titulo]` do que vem depois de `subgraph`. `subgraph Titulo com espacos` e
/// `subgraph "titulo"` nao tem id (nenhuma aresta consegue cita-los), entao viram `None`.
fn parse_subgraph(rest: &str) -> (Option<String>, &str) {
    let id_end = rest
        .find(|c: char| c.is_whitespace() || matches!(c, '[' | '(' | '{' | '"'))
        .unwrap_or(rest.len());
    let (id, after) = rest.split_at(id_end);
    if id.is_empty() {
        return (None, "");
    }
    let after = after.trim();
    if after.is_empty() {
        (Some(id.to_string()), "")
    } else if after.starts_with('[') {
        (Some(id.to_string()), after)
    } else {
        (None, "")
    }
}

fn flatten_flowchart(lines: &[&str]) -> Option<String> {
    let mut items: Vec<Item> = Vec::with_capacity(lines.len());
    let mut depth = 0usize;
    let mut found = false;
    for line in lines {
        let t = line.trim();
        if let Some(rest) = keyword_rest(t, "subgraph") {
            let (id, label) = parse_subgraph(rest);
            depth += 1;
            found = true;
            items.push(Item::Sub {
                indent: indent_of(line),
                id,
                label,
            });
        } else if depth > 0 && matches!(t, "end" | "end;") {
            depth -= 1;
            items.push(Item::End);
        } else if depth > 0 && is_direction(t) {
            items.push(Item::Direction);
        } else {
            items.push(Item::Line(line));
        }
    }
    if !found {
        return None;
    }

    // Quais ids de subgraph uma aresta cita: so esses viram no.
    let ids: Vec<&str> = items
        .iter()
        .filter_map(|item| match item {
            Item::Sub { id: Some(id), .. } => Some(id.as_str()),
            _ => None,
        })
        .collect();
    let mut used: HashSet<&str> = HashSet::new();
    for item in &items {
        let Item::Line(line) = item else { continue };
        if line.trim_start().starts_with("%%") {
            continue;
        }
        let stripped = strip_labels(line);
        if !has_arrow(&stripped) {
            continue;
        }
        for id in &ids {
            if contains_token(&stripped, id) {
                used.insert(*id);
            }
        }
    }
    let dropped: HashSet<&str> = ids
        .iter()
        .copied()
        .filter(|id| !used.contains(id))
        .collect();

    let mut out: Vec<String> = Vec::with_capacity(items.len());
    for item in &items {
        match item {
            Item::Sub {
                indent,
                id: Some(id),
                label,
            } if used.contains(id.as_str()) => out.push(format!("{indent}{id}{label}")),
            Item::Sub { .. } | Item::End | Item::Direction => {}
            Item::Line(line) => {
                if let Some(kept) = without_dropped_refs(line, &dropped) {
                    out.push(kept);
                }
            }
        }
    }
    Some(out.join("\n"))
}

/// Tira de `style`, `class` e `click` a referencia a um subgraph que nao virou no.
fn without_dropped_refs(line: &str, dropped: &HashSet<&str>) -> Option<String> {
    if dropped.is_empty() {
        return Some(line.to_string());
    }
    let mut words = line.split_whitespace();
    match words.next() {
        Some("style") | Some("click") => match words.next() {
            Some(id) if dropped.contains(id) => None,
            _ => Some(line.to_string()),
        },
        Some("class") => {
            let Some(targets) = words.next() else {
                return Some(line.to_string());
            };
            let all: Vec<&str> = targets.split(',').collect();
            let kept: Vec<&str> = all
                .iter()
                .copied()
                .filter(|id| !dropped.contains(id))
                .collect();
            if kept.len() == all.len() {
                Some(line.to_string())
            } else if kept.is_empty() {
                None
            } else {
                let rest: Vec<&str> = words.collect();
                Some(format!(
                    "{}class {} {}",
                    indent_of(line),
                    kept.join(","),
                    rest.join(" ")
                ))
            }
        }
        _ => Some(line.to_string()),
    }
}

// --- state -------------------------------------------------------------------------------------

/// O id de um `state ... {`: `state X {` e `state "descricao" as X {`.
fn composite_id(head: &str) -> Option<&str> {
    let rest = keyword_rest(head, "state")?;
    let id = match rest.rsplit_once(" as ") {
        Some((_, id)) => id,
        None => rest,
    };
    let id = id.trim();
    (!id.is_empty() && !id.contains(char::is_whitespace)).then_some(id)
}

fn flatten_state(lines: &[&str]) -> Option<String> {
    // Ids de estado composto que alguma transicao cita (so estes mantem a linha `state X`).
    let mut cited: HashSet<&str> = HashSet::new();
    let composites: Vec<&str> = lines
        .iter()
        .filter_map(|line| {
            let t = line.trim();
            let head = t.strip_suffix('{')?.trim_end();
            composite_id(head)
        })
        .collect();
    if composites.is_empty() {
        return None;
    }
    for line in lines {
        let t = line.trim();
        if t.starts_with("%%") || !t.contains("-->") {
            continue;
        }
        // O que vem depois de `:` e rotulo da transicao.
        let structure = t.split(':').next().unwrap_or(t);
        for id in &composites {
            if contains_token(structure, id) {
                cited.insert(id);
            }
        }
    }

    let mut out: Vec<String> = Vec::with_capacity(lines.len());
    let mut depth = 0usize;
    for line in lines {
        let t = line.trim();
        if let Some(head) = t.strip_suffix('{').map(str::trim_end) {
            if let Some(id) = composite_id(head) {
                depth += 1;
                if cited.contains(id) {
                    out.push(format!("{}{head}", indent_of(line)));
                }
                continue;
            }
        }
        if depth > 0 && t == "}" {
            depth -= 1;
        } else if depth > 0 && (t == "--" || is_direction(t)) {
            // Concorrencia e direcao de composto nao existem num grafo plano.
        } else {
            out.push((*line).to_string());
        }
    }
    Some(out.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flat(src: &str) -> String {
        flatten(src).expect("deveria achatar").0
    }

    #[test]
    fn family_ignores_front_matter_comments_and_directives() {
        let src = "---\ntitle: x\n---\n%%{init: {}}%%\n%% nota\n\nflowchart LR\n  subgraph S\n    A\n  end";
        assert_eq!(
            family(&src.lines().collect::<Vec<_>>()),
            Some(Family::Flowchart)
        );
        assert_eq!(
            family(&["stateDiagram-v2", "state X {"]),
            Some(Family::State)
        );
        assert_eq!(family(&["sequenceDiagram", "subgraph x"]), None);
        assert_eq!(family(&[]), None);
    }

    #[test]
    fn no_subgraph_means_nothing_to_flatten() {
        assert!(flatten("flowchart TD\n  A --> B").is_none());
        assert!(flatten("stateDiagram-v2\n  [*] --> A").is_none());
        assert!(flatten("sequenceDiagram\n  subgraph x\n  A->>B: hi").is_none());
        assert!(flatten("").is_none());
    }

    #[test]
    fn flowchart_drops_subgraph_end_and_inner_direction() {
        let src = "flowchart TB\n  subgraph G[\"Grupo\"]\n    direction LR\n    A --> B\n  end\n  B --> C";
        let out = flat(src);
        assert_eq!(out, "flowchart TB\n    A --> B\n  B --> C");
    }

    #[test]
    fn flowchart_nested_subgraphs_are_all_removed() {
        let src = "flowchart LR\n  subgraph Outer\n    subgraph Inner\n      direction TB\n      A\n    end\n    B\n  end\n  A --> B";
        let out = flat(src);
        assert!(!out.contains("subgraph"), "{out}");
        assert!(!out.lines().any(|l| l.trim() == "end"), "{out}");
        assert!(!out.contains("direction"), "{out}");
        assert!(out.contains("A --> B"), "{out}");
    }

    #[test]
    fn flowchart_edge_to_a_subgraph_id_becomes_a_plain_node_with_its_title() {
        let src = "flowchart TB\n  subgraph API[\"⚡ API REST\"]\n    H[\"/health\"]\n  end\n  FE -->|\"HTTP\"| API\n  API --> DB";
        let out = flat(src);
        assert!(out.contains("API[\"⚡ API REST\"]"), "{out}");
        assert!(out.contains("FE -->|\"HTTP\"| API"), "{out}");
        assert!(out.contains("API --> DB"), "{out}");
    }

    #[test]
    fn flowchart_unreferenced_subgraph_disappears_with_its_styling() {
        let src = "flowchart TB\n  subgraph S1[Um]\n    A\n  end\n  subgraph S2[Dois]\n    B\n  end\n  A --> B\n  style S1 fill:#fff\n  class S1,A cls\n  click S2 href \"x\"";
        let out = flat(src);
        assert!(!out.contains("S1"), "{out}");
        assert!(!out.contains("S2"), "{out}");
        assert!(out.contains("class A cls"), "{out}");
    }

    #[test]
    fn flowchart_label_text_does_not_count_as_a_reference() {
        // `S` aparece so dentro do rotulo: nao e ponta de aresta.
        let src =
            "flowchart TB\n  subgraph S\n    A\n  end\n  A -->|\"vai para S\"| B[\"S e aqui\"]";
        let out = flat(src);
        assert!(!out.lines().any(|l| l.trim() == "S"), "{out}");
    }

    #[test]
    fn flowchart_subgraph_without_an_id_form_has_no_node() {
        let src = "flowchart TB\n  subgraph Titulo com espacos\n    A\n  end\n  A --> B";
        let out = flat(src);
        assert_eq!(out, "flowchart TB\n    A\n  A --> B");
    }

    #[test]
    fn flowchart_keeps_the_edge_order_so_link_style_indices_stay_valid() {
        let src = "flowchart TB\n  subgraph S\n    A\n  end\n  X --> S\n  S --> Y\n  linkStyle 0 stroke:red\n  linkStyle 1 stroke:blue";
        let out = flat(src);
        let edges: Vec<&str> = out.lines().filter(|l| l.contains("-->")).collect();
        assert_eq!(edges, vec!["  X --> S", "  S --> Y"]);
        assert!(out.contains("linkStyle 1 stroke:blue"), "{out}");
    }

    #[test]
    fn state_composite_loses_braces_and_concurrency() {
        let src = "stateDiagram-v2\n  [*] --> Active\n  state Active {\n    direction LR\n    [*] --> A\n    A --> B\n    --\n    [*] --> C\n  }\n  Active --> [*]";
        let out = flat(src);
        assert!(!out.contains('{') && !out.contains('}'), "{out}");
        assert!(!out.lines().any(|l| l.trim() == "--"), "{out}");
        assert!(!out.contains("direction"), "{out}");
        assert!(out.contains("state Active"), "{out}");
        assert!(out.contains("Active --> [*]"), "{out}");
    }

    #[test]
    fn state_uncited_composite_declaration_is_dropped() {
        let src = "stateDiagram-v2\n  state Fora {\n    state Dentro {\n      [*] --> X\n    }\n    [*] --> Dentro\n  }";
        let out = flat(src);
        assert!(!out.contains("state Fora"), "{out}");
        // `Dentro` e citado por uma transicao.
        assert!(out.contains("state Dentro"), "{out}");
        assert!(!out.contains('{'), "{out}");
    }

    #[test]
    fn state_composite_with_a_description_keeps_the_alias_form() {
        let src =
            "stateDiagram-v2\n  state \"Em andamento\" as Run {\n    [*] --> A\n  }\n  [*] --> Run";
        let out = flat(src);
        assert!(out.contains("state \"Em andamento\" as Run"), "{out}");
        assert!(!out.contains('{'), "{out}");
    }

    #[test]
    fn flatten_is_idempotent_and_never_panics_on_odd_input() {
        let src = "flowchart TB\n  subgraph S\n    A\n  end\n  A --> S";
        let once = flat(src);
        assert!(flatten(&once).is_none(), "{once}");
        for odd in [
            "flowchart TB\nsubgraph",
            "flowchart TB\nsubgraph \"\"",
            "flowchart TB\nsubgraph [x]\nend\nend\nend",
            "flowchart TB\nsubgraph ✨🚀[x]\nA-->✨🚀\nend",
            "stateDiagram-v2\nstate {",
            "stateDiagram-v2\nstate  as {\n}\n}",
            "graph\n  subgraph a\n",
        ] {
            let _ = flatten(odd);
        }
    }
}
