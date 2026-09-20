# deckle.nvim

Preview de Markdown num buffer separado somente-leitura dentro do Neovim. Lua faz tudo que
encosta na API do editor. Um `.so` opcional em Rust (via mlua) renderiza Mermaid em arte de
texto usando o crate `merman`.

**Estado: só documentação.** Não existe `lua/`, `crates/`, `tests/` nem `scripts/`. Antes de
rodar qualquer comando de build ou teste, confira se ele já existe. Nenhum deles existe hoje.

## Leia antes de decidir

- `docs/architecture.md` (camadas, pipeline, contrato Lua↔Rust, estrutura de diretórios)
- `docs/roadmap.md` (fases, entregas, gates de saída, anti-escopo)
- `docs/validation.md` (o que foi medido; os números vêm daqui)
- `docs/adr/` (as quatro decisões travadas)

A seção 12 da arquitetura lista o que **não** foi validado. Não trate nada dela como fato.

## Idioma

Documentação, comentários, commits e PRs em **português**. Nomes de código, símbolos e
mensagens de erro do plugin em inglês.

## Regras que vêm dos ADRs

Quebrar qualquer uma destas invalida uma decisão já tomada. Se for realmente necessário,
escreva um ADR novo antes de escrever o código.

1. **O buffer fonte é intocável.** Nenhum extmark, nenhum conceal, nenhum `modifiable = false`
   nele. Todo render vai para o buffer de preview. (ADR-0003)
2. **Rust nunca chama a API do Neovim.** O contrato é `String` entra, `Vec<String>` sai. É o
   que mantém o crate testável com `cargo test` puro. (ADR-0001)
3. **No Rust, sempre `Err`, nunca `panic!` deliberado.** Os dois viram erro de Lua capturável
   com mlua, mas só o `Err` produz mensagem útil. (V2.2)
4. **Nada de `nvim-oxi`.** Com ele, retornar `Err` aborta o processo do Neovim, exit 134,
   trabalho não salvo perdido. Medido. (ADR-0001, V2)
5. **Todo caminho de degradação precisa de teste que force a degradação.** Remover o `.so`,
   passar diagrama inválido, esconder o parser da linguagem. Comentário dizendo que funciona
   não conta. (ADR-0004)
6. **Largura de texto é `vim.fn.strdisplaywidth`, nunca `#str`.** Emoji e CJK entram no teste
   junto com a feature, não depois.
7. **Índices de linha são 0-indexados com fim exclusivo em todo o IR.** É o que o treesitter e
   a API de buffer usam. Converta nas bordas, nunca no meio.

## Pinos e versões

| | valor | por quê |
|---|---|---|
| Neovim | piso **0.11.0** | é a única versão medida. 0.10 é suposição |
| Rust | `rust-toolchain.toml` em **1.95** | MSRV do merman |
| merman-core / merman-ascii | `=0.8.0-alpha.6`, **idêntica nos dois** | alpha que quebra API entre versões |

Com rustc 1.93 o cargo resolve merman para `0.7.0-alpha.1` **sem avisar**, e essa versão não
suporta `sequenceDiagram`. O build precisa falhar alto nesse caso, não seguir em frente.

## Armadilhas já pagas uma vez

- O cargo gera `libdeckle_native.so`, mas o `require` do Lua só acha `deckle_native.so`. O
  prefixo `lib` some na instalação.
- Um `.so` velho no lugar faz o teste passar com `attempt to call a nil value`, que parece
  sucesso e não é. Trave o script se o build falhar. Aconteceu duas vezes durante a validação.
- Sempre confira o exit code do `nvim --headless`. **134 é abort**, não falha de teste.
- O buffer de preview não tem `filetype=markdown`, então a injeção de treesitter em code block
  não acontece sozinha. O highlight é refeito à mão com `get_string_parser`.

## Fluxo de trabalho

Uma fase do roadmap é um PR. Branch `feat/f<N>-<slug>` a partir da `main`. PR não entra sem
passar no gate de saída da própria fase, que está escrito no roadmap.

Commits em Angular/Conventional, atômicos, **sem corpo e sem co-autor**.

Fase sem teste é fase não terminada.

## Fora de escopo do projeto inteiro

Não proponha, não implemente, não "deixe preparado para".

- Editar vendo o render ao lado no mesmo texto. Isso é markview.nvim.
- Exportar para HTML ou PDF.
- LaTeX, KaTeX.
- Servidor web, webview, browser.
- Suporte a Vim.
