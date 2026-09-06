# ADR-0001 — `mlua` em vez de `nvim-oxi`

**Status:** aceito · **Data:** 2026-09-06

## Contexto

O componente nativo em Rust precisa ser carregável por `require` dentro do Neovim.
Os dois caminhos in-process são `nvim-oxi` (bindings tipados da API do Neovim) e
`mlua` com feature `module` (bindings genéricos de LuaJIT).

`nvim-oxi` é a escolha aparentemente óbvia: existe para exatamente isso e tem API tipada.

## Decisão

Usar **`mlua`** com features `module` + `luajit`.

## Razão

Um erro no renderer de mermaid com `nvim-oxi` **aborta o processo do Neovim**
(SIGABRT, exit 134), levando junto o trabalho não salvo do usuário. Medido em
[V2](../validation.md#v2--um-panic-em-rust-atravessando-ffi-mata-o-neovim):
tanto um `panic!` quanto o simples retorno de `Err` produzem
`panic in a function that cannot unwind` → `abort()`. `pcall` não captura.

Com `mlua`, os dois casos viram erro de Lua capturável e o módulo continua utilizável.

Para um plugin da comunidade, onde a entrada é markdown arbitrário de terceiros, essa
diferença é a única que importa. Um diagrama malformado precisa degradar aquele bloco,
não encerrar a sessão.

Fatores secundários que apontam na mesma direção:

- `nvim-oxi` 0.6.0 (crates.io) está ~15 meses atrás do `master`, que já removeu
  `neovim-0-10` e adicionou `neovim-0-12`. Quem usa a versão publicada pega ABI velha.
- Issues abertas de ABI reais: [#311][311] (`set_hl` aborta em 0.12 por keyset
  desatualizado), [#231][231] (desserialização errada crasha), [#278][278]
  (`from_fn_once` crasha quando o `setup()` é chamado duas vezes).
- O `blink.cmp`, plugin Neovim com backend Rust mais instalado, **usa `mlua`**, não
  `nvim-oxi`.

`deckle` não precisa da API do Neovim dentro do Rust — o contrato é `String` entra,
`Vec<String>` sai. A camada tipada do `nvim-oxi` não paga por si mesma aqui.

[311]: https://github.com/noib3/nvim-oxi/issues/311
[231]: https://github.com/noib3/nvim-oxi/issues/231
[278]: https://github.com/noib3/nvim-oxi/issues/278

## Consequências

- Nenhuma chamada à API do Neovim pode acontecer dentro do Rust. Isso vira restrição
  arquitetural, e é boa: mantém o crate testável com `cargo test` puro.
- A conversão de tipos é manual (`mlua::Table`), sem os tipos do Neovim prontos.
- Ganhamos o mesmo caminho de distribuição já trilhado pelo `blink.cmp`.
