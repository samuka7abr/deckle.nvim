//! Pos-processamento das linhas que o merman devolve (etapa 3 da branch
//! `fix/mermaid-showcase`).
//!
//! Rust puro, como o resto da logica (ADR-0001): `Vec<String>` entra, `Vec<String>` sai.
//!
//! # Entidades HTML
//!
//! Em flowchart e state o merman 0.8.0 deixa `&lt;`, `&gt;` e `&amp;` literais nos rotulos
//! (V11): o fonte `A["a &lt; b"]` sai `a &lt; b`, com a caixa dimensionada para os 4
//! caracteres da entidade. [`decode_entities`] decodifica as cinco entidades que o Mermaid
//! documenta para esse fim (`&lt;`, `&gt;`, `&amp;`, `&quot;` e `&#39;`) nas linhas ja
//! desenhadas, e **preserva a largura de cada linha**, que e o ponto delicado: a entidade
//! ocupa de 4 a 6 celulas e o caractere decodificado, uma, entao a caixa ficaria torta.
//!
//! A compensacao e local. A linha e dividida nos caracteres de borda (`│`, `┌`, `|`...), e a
//! sequencia entre duas bordas e um "trecho": o texto de um no, com o recuo dos dois lados.
//! Num trecho com entidade, as celulas que sobraram voltam como espacos ao redor do texto,
//! repartidos na proporcao do recuo que ele ja tinha (centralizado continua centralizado,
//! alinhado a esquerda continua alinhado). Um trecho que nao termina numa borda (rotulo de
//! aresta no fim da linha) so encolhe: nao ha nada a sua direita para deslocar.
//!
//! As sequencias de escape SGR da saida colorida (etapa 4) sao tokens de largura zero: nao
//! contam como recuo e nunca sao separadas do texto que coloriam.
//!
//! # O que NAO e limpo aqui
//!
//! As linhas `type(bytes=3)="int" name(bytes=2)=...` do ER e os `text(bytes=..)` do class
//! nao sao um defeito de decodificacao: o merman-ascii 0.8.0 as emite de proposito
//! ("divulgacao do texto autoral", `er/render.rs` e `class/render.rs`), sem opcao que as
//! desligue. Filtra-las exigiria reconhecer o formato por regex, que quebra no primeiro
//! rotulo que o contenha. Ficam como limitacao documentada (`docs/validation.md`, V11).

/// Cor-sentinela do tema do merman. Em TrueColor o merman pinta **todo** elemento com a cor do
/// papel dele no tema (texto `#27272a`, borda `#a1a1aa`...), e nao so o que o diagrama estiliza.
/// Essas cores sao de um tema claro e iriam por cima do esquema de cores do usuario. O `render.rs`
/// monta um tema em que todo papel "de tema" tem esta cor, e [`drop_theme_colors`] tira os
/// escapes dela: sobra so a cor que o diagrama pediu (`classDef`, `style`, `linkStyle`, `box
/// rgb`, `rect rgb`) e o que e dado (as series de um xychart).
pub(crate) const THEME_SENTINEL: (u8, u8, u8) = (1, 2, 3);

/// Tira das linhas os escapes de cor da [`THEME_SENTINEL`] (de frente e de fundo) e os
/// `ESC[0m` que ficam sem nada para fechar. Escape tem largura zero: a largura nao muda.
pub(crate) fn drop_theme_colors(lines: Vec<String>) -> Vec<String> {
    let (r, g, b) = THEME_SENTINEL;
    let sentinels = [
        format!("\u{1b}[38;2;{r};{g};{b}m"),
        format!("\u{1b}[48;2;{r};{g};{b}m"),
    ];
    lines
        .into_iter()
        .map(|line| {
            if !line.contains('\u{1b}') {
                return line;
            }
            let mut out = String::with_capacity(line.len());
            // Ha algum estilo aberto que um reset fecharia?
            let mut open = false;
            for tok in tokenize(&line) {
                match tok {
                    Tok::Ch(c) => out.push(c),
                    Tok::Esc(seq) if sentinels.contains(&seq) => {}
                    Tok::Esc(seq) if seq == "\u{1b}[0m" || seq == "\u{1b}[m" => {
                        if open {
                            out.push_str(&seq);
                            open = false;
                        }
                    }
                    Tok::Esc(seq) => {
                        open = true;
                        out.push_str(&seq);
                    }
                }
            }
            out
        })
        .collect()
}

/// As entidades decodificadas. `&amp;` vem decodificado uma vez so: `&amp;lt;` vira `&lt;`.
const ENTITIES: &[(&str, char)] = &[
    ("&lt;", '<'),
    ("&gt;", '>'),
    ("&amp;", '&'),
    ("&quot;", '"'),
    ("&#39;", '\''),
];

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    /// Sequencia `ESC [ ... <final>` (SGR e afins): largura zero.
    Esc(String),
    Ch(char),
}

/// Decodifica as entidades de cada linha, mantendo a largura. Linha sem `&` volta como esta.
pub(crate) fn decode_entities(lines: Vec<String>) -> Vec<String> {
    lines.into_iter().map(decode_line).collect()
}

fn decode_line(line: String) -> String {
    if !line.contains('&') || !ENTITIES.iter().any(|(entity, _)| line.contains(entity)) {
        return line;
    }
    let toks = tokenize(&line);
    let mut out: Vec<Tok> = Vec::with_capacity(toks.len());

    // Trecho = tokens entre duas bordas. `start` e o primeiro token do trecho aberto.
    let mut start = 0usize;
    let mut i = 0usize;
    while i <= toks.len() {
        let at_end = i == toks.len();
        let boundary = !at_end && is_boundary(&toks, i);
        if at_end || boundary {
            let left_bounded = start > 0;
            let right_bounded = boundary;
            decode_run(&toks[start..i], left_bounded, right_bounded, &mut out);
            if boundary {
                out.push(toks[i].clone());
            }
            start = i + 1;
        }
        i += 1;
    }
    render(&out)
}

fn tokenize(line: &str) -> Vec<Tok> {
    let chars: Vec<char> = line.chars().collect();
    let mut toks = Vec::with_capacity(chars.len());
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '\u{1b}' && chars.get(i + 1) == Some(&'[') {
            let mut end = i + 2;
            while end < chars.len() && !('\u{40}'..='\u{7e}').contains(&chars[end]) {
                end += 1;
            }
            let stop = (end + 1).min(chars.len());
            toks.push(Tok::Esc(chars[i..stop].iter().collect()));
            i = stop;
        } else {
            toks.push(Tok::Ch(chars[i]));
            i += 1;
        }
    }
    toks
}

fn render(toks: &[Tok]) -> String {
    let mut out = String::new();
    for tok in toks {
        match tok {
            Tok::Esc(seq) => out.push_str(seq),
            Tok::Ch(c) => out.push(*c),
        }
    }
    out
}

/// Caractere de borda: o desenho de caixa do Unicode, e `|` quando tem espaco ao lado ou esta
/// na ponta da linha (a borda do charset ASCII; um `|` colado em letras e texto de rotulo).
fn is_boundary(toks: &[Tok], at: usize) -> bool {
    let Tok::Ch(c) = toks[at] else { return false };
    if ('\u{2500}'..='\u{257f}').contains(&c) {
        return true;
    }
    if c != '|' {
        return false;
    }
    let visible = |idx: Option<usize>| match idx.and_then(|i| toks.get(i)) {
        Some(Tok::Ch(n)) => Some(*n),
        _ => None,
    };
    let prev = visible(at.checked_sub(1));
    let next = visible(Some(at + 1));
    prev.is_none_or(|p| p == ' ') || next.is_none_or(|n| n == ' ')
}

/// Decodifica um trecho e, se ele termina numa borda, devolve as celulas poupadas como
/// espacos ao redor do texto.
fn decode_run(run: &[Tok], left_bounded: bool, right_bounded: bool, out: &mut Vec<Tok>) {
    let mut decoded: Vec<Tok> = Vec::with_capacity(run.len());
    let mut removed = 0usize;
    let mut i = 0usize;
    while i < run.len() {
        if let Some((len, ch)) = entity_at(run, i) {
            decoded.push(Tok::Ch(ch));
            removed += len - 1;
            i += len;
        } else {
            decoded.push(run[i].clone());
            i += 1;
        }
    }
    if removed == 0 || !right_bounded {
        out.extend(decoded);
        return;
    }

    let is_space = |tok: &Tok| matches!(tok, Tok::Ch(' '));
    let is_visible = |tok: &Tok| matches!(tok, Tok::Ch(_));
    let first = decoded.iter().position(|t| is_visible(t) && !is_space(t));
    let last = decoded.iter().rposition(|t| is_visible(t) && !is_space(t));
    let (Some(first), Some(last)) = (first, last) else {
        out.extend(decoded);
        return;
    };
    let lead = decoded[..first].iter().filter(|t| is_space(t)).count();
    let trail = decoded[last + 1..].iter().filter(|t| is_space(t)).count();

    let (extra_left, extra_right) = if left_bounded && lead + trail > 0 {
        let slack = lead + trail;
        let left = (lead * removed + slack / 2) / slack;
        (left, removed - left)
    } else {
        (0, removed)
    };

    for (idx, tok) in decoded.into_iter().enumerate() {
        if idx == first {
            out.extend(std::iter::repeat_n(Tok::Ch(' '), extra_left));
        }
        out.push(tok);
        if idx == last {
            out.extend(std::iter::repeat_n(Tok::Ch(' '), extra_right));
        }
    }
}

/// Se uma entidade comeca em `run[at]`: o comprimento dela em tokens e o caractere.
fn entity_at(run: &[Tok], at: usize) -> Option<(usize, char)> {
    if run[at] != Tok::Ch('&') {
        return None;
    }
    ENTITIES.iter().find_map(|(entity, decoded)| {
        let matches = entity
            .chars()
            .enumerate()
            .all(|(offset, c)| run.get(at + offset) == Some(&Tok::Ch(c)));
        matches.then(|| (entity.chars().count(), *decoded))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Largura em celulas de um texto sem escapes: 2 para CJK e emoji, 1 para o resto. Basta
    /// para os casos do teste (nao e o `unicode-width`).
    fn cells(s: &str) -> usize {
        s.chars()
            .map(|c| {
                if (c as u32) >= 0x2e80 && !('\u{2500}'..='\u{257f}').contains(&c) {
                    2
                } else {
                    1
                }
            })
            .sum()
    }

    fn strip_escapes(s: &str) -> String {
        render(
            &tokenize(s)
                .into_iter()
                .filter(|t| matches!(t, Tok::Ch(_)))
                .collect::<Vec<_>>(),
        )
    }

    fn one(line: &str) -> String {
        decode_entities(vec![line.to_string()]).remove(0)
    }

    #[test]
    fn decodes_each_of_the_five_entities() {
        for (entity, expected) in [
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
        ] {
            let line = format!("│ a {entity} b │");
            let out = one(&line);
            assert!(out.contains(&format!("a {expected} b")), "{entity}: {out}");
            assert!(!out.contains(entity), "{entity}: {out}");
            assert_eq!(cells(&out), cells(&line), "{entity}: largura mudou: {out}");
        }
    }

    #[test]
    fn keeps_the_box_aligned_and_the_label_centered() {
        // Recuo 1 + 1, e 3 celulas poupadas: 2 voltam a esquerda e 1 a direita (arredonda para
        // o lado em que o recuo e maior ou igual).
        let line = "│ a &lt; b │";
        let out = one(line);
        assert_eq!(out, "│   a < b  │");
        assert_eq!(cells(&out), cells(line));
    }

    #[test]
    fn keeps_left_aligned_text_left_aligned() {
        // Sem recuo a esquerda do texto (so o espaco da borda): a sobra vai toda a direita.
        let line = "│a &lt; b      │";
        let out = one(line);
        assert!(out.starts_with("│a < b"), "{out}");
        assert_eq!(cells(&out), cells(line));
    }

    #[test]
    fn a_decoded_amp_is_not_decoded_again() {
        let out = one("│ x &amp;lt; y │");
        assert!(out.contains("x &lt; y"), "{out}");
        assert!(!out.contains("x < y"), "{out}");
        assert_eq!(cells(&out), cells("│ x &amp;lt; y │"));
    }

    #[test]
    fn leaves_unknown_entities_and_plain_ampersands_alone() {
        for line in [
            "│ a &copy; b │",
            "│ a & b │",
            "│ &unknown; │",
            "│ a &lt b │", // sem o ponto e virgula
            "┌─────┐",
            "",
        ] {
            assert_eq!(one(line), line);
        }
    }

    #[test]
    fn several_entities_in_one_label_and_several_boxes_in_one_row() {
        let line = "│ &lt;a&gt; &amp; &quot;b&quot; │     │ &#39;c&#39; │";
        let out = one(line);
        assert!(out.contains("<a> & \"b\""), "{out}");
        assert!(out.contains("'c'"), "{out}");
        assert_eq!(cells(&out), cells(line));
        // Cada borda continua na mesma coluna.
        let cols = |s: &str| -> Vec<usize> {
            let mut at = 0;
            let mut found = Vec::new();
            for c in s.chars() {
                if c == '│' {
                    found.push(at);
                }
                at += cells(&c.to_string());
            }
            found
        };
        assert_eq!(cols(&out), cols(line), "{out}");
    }

    #[test]
    fn a_label_at_the_end_of_the_row_just_shrinks() {
        // Rotulo de aresta: depois dele nao ha borda para deslocar.
        let out = one("   │ a &lt; b");
        assert_eq!(out, "   │ a < b");
    }

    #[test]
    fn cjk_and_emoji_labels_keep_their_display_width() {
        let line = "│ 你好 &lt; 世界 🚀 │";
        let out = one(line);
        assert!(out.contains("你好"), "{out}");
        assert!(out.contains("<"), "{out}");
        assert_eq!(cells(&out), cells(line), "{out}");
    }

    #[test]
    fn works_in_the_ascii_charset() {
        let line = "| a &lt; b |";
        let out = one(line);
        assert_eq!(out, "|   a < b  |");
        // `|` colado em letras e texto, nao borda.
        let text = one("a|b &lt; c");
        assert_eq!(text, "a|b < c");
    }

    #[test]
    fn color_escapes_are_zero_width_and_stay_attached() {
        let line = "\u{1b}[38;2;1;2;3m│\u{1b}[0m\u{1b}[48;2;9;9;9m a &lt; b \u{1b}[0m\u{1b}[38;2;1;2;3m│\u{1b}[0m";
        let out = one(line);
        // Mesma contagem de escapes, na mesma ordem.
        let escapes = |s: &str| -> Vec<String> {
            tokenize(s)
                .into_iter()
                .filter_map(|t| match t {
                    Tok::Esc(e) => Some(e),
                    Tok::Ch(_) => None,
                })
                .collect()
        };
        assert_eq!(escapes(&out), escapes(line));
        let plain = strip_escapes(&out);
        assert_eq!(plain, "│   a < b  │");
        assert_eq!(cells(&plain), cells(&strip_escapes(line)));
        // O fundo continua cobrindo o texto: as celulas extras estao depois do escape de fundo
        // e antes do reset.
        assert!(
            out.contains("\u{1b}[48;2;9;9;9m   a < b  \u{1b}[0m"),
            "{out:?}"
        );
    }

    #[test]
    fn truncated_escape_never_panics() {
        for odd in [
            "\u{1b}",
            "\u{1b}[",
            "\u{1b}[38;2",
            "│\u{1b}[31 &lt; │",
            "&",
            "&lt",
            "&lt;",
        ] {
            let _ = one(odd);
        }
        assert_eq!(one("&lt;"), "<");
    }

    fn sentinel_fg() -> String {
        let (r, g, b) = THEME_SENTINEL;
        format!("\u{1b}[38;2;{r};{g};{b}m")
    }

    #[test]
    fn theme_colors_go_away_and_authored_colors_stay() {
        let s = sentinel_fg();
        let authored = "\u{1b}[38;2;21;101;192m\u{1b}[48;2;227;242;253m";
        let line = format!("{s}│\u{1b}[0m {authored}Start\u{1b}[0m {s}─\u{1b}[0m");
        let out = drop_theme_colors(vec![line]).remove(0);
        // Sobra so o trecho estilizado, com o reset dele, e o resto e texto puro.
        assert_eq!(out, format!("│ {authored}Start\u{1b}[0m ─"));
        assert!(!out.contains("38;2;1;2;3"));
    }

    #[test]
    fn theme_color_stripping_never_changes_the_visible_text() {
        let s = sentinel_fg();
        let bg = "\u{1b}[48;2;1;2;3m";
        let line = format!("{s}{bg}┌──┐\u{1b}[0m \u{1b}[1mx\u{1b}[0m");
        let out = drop_theme_colors(vec![line.clone()]).remove(0);
        assert_eq!(strip_escapes(&out), strip_escapes(&line));
        assert_eq!(out, "┌──┐ \u{1b}[1mx\u{1b}[0m");
    }

    #[test]
    fn lines_without_escapes_are_untouched_by_the_theme_strip() {
        let lines = vec!["┌──┐".to_string(), String::new(), "a &lt; b".to_string()];
        assert_eq!(drop_theme_colors(lines.clone()), lines);
    }

    #[test]
    fn lines_without_entities_are_returned_untouched() {
        let lines = vec!["┌──┐".to_string(), "│ok│".to_string(), String::new()];
        assert_eq!(decode_entities(lines.clone()), lines);
    }
}
