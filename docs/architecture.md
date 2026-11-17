# Arquitetura

> Todas as decisões abaixo foram validadas empiricamente antes de serem escritas.
> As medições e os comandos para reproduzi-las estão em [validation.md](validation.md).
> O que **não** foi validado está listado na última seção — leia antes de confiar.

## 1. O que é

Um preview de Markdown que abre num **buffer separado, somente-leitura**, ao lado do
fonte — o modelo do Zed, não o das plugins que decoram o buffer original in-place.

O que isso implica:

| | buffer separado (deckle) | decoração in-place (markview, render-markdown) |
|---|---|---|
| edição enquanto vê | não | sim |
| sincronia fonte↔render | precisa ser construída | grátis |
| liberdade de layout | total (reflow, reordenar, expandir) | limitada ao texto original |
| diagramas ocupando N linhas | natural | precisa de `virt_lines` |

A troca é deliberada: pagar o custo da sincronia para ganhar liberdade total de layout,
que é o que permite renderizar um diagrama de 40 linhas a partir de um bloco de 6.

## 2. Princípios

1. **Zero dependência obrigatória além do Neovim.** Validado: os parsers `markdown` e
   `markdown_inline` vêm do core do Neovim (`/usr/lib64/nvim/parser/`), não do
   nvim-treesitter. Nenhum outro plugin é necessário.
2. **Progressive enhancement.** Capacidades extras são detectadas em runtime. A ausência
   melhora ou piora o resultado, nunca quebra o plugin.
3. **Nada pode matar o editor.** Não é retórica: um `panic!` em Rust atravessando FFI
   **aborta o processo do Neovim** (SIGABRT, exit 134, trabalho não salvo perdido).
   A escolha de biblioteca no ADR-0001 existe por causa disso.
4. **Degradação por feature, não do plugin.** Se o componente nativo não carregar,
   o mermaid vira bloco de código cru e todo o resto continua funcionando.

## 3. Camadas

```
   buffer fonte (.md)
          │
          ▼
┌─────────────────────────────────────────────────────┐
│  LUA — tudo que encosta no Neovim                   │
│                                                     │
│  treesitter (markdown + markdown_inline)  ← core    │
│  IR de blocos → layout de texto (wrap/largura)      │
│  buffer de preview (nomodifiable) + extmarks        │
│  scroll sync · detecção de capacidade · comandos    │
└──────────────────────┬──────────────────────────────┘
                       │  fronteira grossa:
                       │  1 chamada por bloco mermaid
                       ▼
┌─────────────────────────────────────────────────────┐
│  RUST — deckle_native (cdylib via mlua)   OPCIONAL  │
│                                                     │
│  merman-core   : mermaid → modelo semântico tipado  │
│  merman-ascii  : modelo → grid de caracteres        │
└─────────────────────────────────────────────────────┘
```

Nenhuma chamada à API do Neovim acontece dentro do Rust. É o que mantém o custo do FFI
baixo, o crate testável isolado com `cargo test`, e a superfície de crash mínima.

## 4. Pipeline de render

```
fonte → treesitter → IR (lista de blocos) → medir largura → emitir linhas + spans
                                                  │
                          bloco ```mermaid ───────┤
                                                  ▼
                                    deckle_native.render(src, opts)
                                                  ▼
                                       linhas de arte ASCII/Unicode
```

O IR é uma lista plana de blocos com metadado de origem. Cada bloco carrega
`src_start` / `src_end` (linhas no fonte), que é o que alimenta a sincronia de scroll.

## 5. Fronteira Lua ↔ Rust

Uma chamada por diagrama. Sem conversas de ida e volta.

```lua
-- Lua
local native = require("deckle_native")   -- lua/deckle_native.so, via `make native`

local ok, lines = pcall(native.render, src, {
  width         = 80,          -- meta de largura em células (default 80), não é corte
  charset       = "unicode",   -- "unicode" (default) | "ascii"
  diagram_ty    = "flowchart", -- opcional: id de tipo do Mermaid já conhecido; pula a detecção
  max_src_lines = 200,         -- opcional (default 200): acima disso é erro, não render
})
-- ok == false → `lines` é uma string de uma linha com o motivo; o bloco degrada para código cru
-- ok == true  → `lines` é string[] (sem "\n"), pronta para nvim_buf_set_lines

native.supported_types()  -- string[]: os 14 tipos do renderer de texto, lidos do merman
native.version()          -- string: versão do crate deckle-native
```

```rust
// Rust — a lógica pura não conhece Lua (crates/deckle-native/src/render.rs)
pub fn render(src: &str, opts: &RenderOptions) -> Result<Vec<String>, RenderError>;
pub fn supported_types() -> Vec<String>;

// a camada mlua é fina (src/binding.rs)
#[mlua::lua_module]
fn deckle_native(lua: &Lua) -> LuaResult<LuaTable>;
```

Contrato de erro: **sempre `Err`, nunca `panic!` deliberado**. O mlua converte os dois em
erro de Lua capturável (validado), mas `Err` produz mensagem útil e `panic!` não. Um
`catch_unwind` em volta do render converte qualquer panic do merman em `Err`.

O valor que o `pcall` devolve em caso de erro é uma **string** pura (`error(msg, 0)`): se o
`Err` fosse entregue direto pelo mlua, o Lua receberia um userdata cujo `tostring` traz um
`stack traceback`. Por isso a função nativa devolve `(nil, msg)` e um wrapper Lua faz o `error`.

Erros que o módulo produz, todos em inglês e em uma linha:

| prefixo da mensagem | causa |
|---|---|
| `invalid option:` | `opts` ou `src` com tipo errado, `width < 1`, `charset` desconhecido |
| `empty mermaid source` | fonte vazia ou só com espaços |
| `mermaid source too large:` | mais de `max_src_lines` linhas (a guarda corre antes do layout) |
| `mermaid parse error:` | sintaxe inválida, tipo não detectado ou `diagram_ty` desconhecido |
| `unsupported diagram:` | diagrama válido que o renderer de texto não cobre (`pie`, `c4`...) |
| `mermaid render failed:` | limite de recursos do merman, ou diagrama que não desenha nada |
| `internal error (panic caught):` | panic capturado; não deveria acontecer |

`width` é uma meta, não um corte: o merman nunca trunca (perderia dado). Se o layout padrão
passa dela, o crate tenta o perfil compacto (só flowchart e sequence o aceitam) e devolve o
mais estreito. Se ainda assim sobrar linha larga, ela vem inteira, e decidir o que fazer
com ela é da camada Lua.

## 6. Camadas de degradação

Cada linha funciona sozinha. O plugin nunca depende de estar numa linha específica.

| Camada | Requisito | Mermaid vira | Imagens viram |
|---|---|---|---|
| **0** | só Neovim | bloco de código cru | texto alternativo |
| **1** | + `deckle_native` (Rust) | **arte Unicode/ASCII** | texto alternativo |
| **2** | + protocolo gráfico do terminal | arte Unicode/ASCII | **imagem de verdade** |
| **3** | + `mmdc` no PATH (opcional) | imagem rasterizada | imagem de verdade |

A camada 1 é o alvo principal e funciona em **qualquer terminal** — tty, ssh, tmux, CI.
Isso é o oposto da abordagem usual, que trata gráficos de terminal como o caminho feliz.

A camada 0 existe porque `require` de um `.so` ausente falha de forma capturável
(validado), então o plugin carrega e funciona mesmo sem binário nenhum.

## 7. Sincronização de scroll

É o custo do buffer separado, e o único problema arquitetural sem solução pronta.

Durante o render, cada bloco emitido registra `preview_line → src_line`. Isso vira dois
arrays ordenados, e a sincronia é uma busca binária em cima deles:

- `CursorMoved` no fonte → acha a linha de preview → `nvim_win_set_cursor` no preview
- `CursorMoved` no preview → caminho inverso
- guarda um flag reentrante para os dois autocmds não se dispararem em loop

O mapa é parcial de propósito: um bloco mermaid de 40 linhas mapeia para as 6 do fonte.
A busca binária resolve para o bloco que contém a linha, não para uma linha exata.

## 8. Estrutura

```
deckle.nvim/
├── lua/deckle/
│   ├── init.lua          setup, comandos
│   ├── parse.lua         treesitter → IR
│   ├── render/           IR → linhas + spans (um módulo por tipo de bloco)
│   ├── preview.lua       janela, buffer, extmarks
│   ├── sync.lua          scroll sync
│   ├── native.lua        carrega o .so, degrada se ausente
│   ├── caps.lua          detecção de capacidade de terminal
│   └── health.lua        :checkhealth deckle
├── crates/deckle-native/ cdylib mlua → merman
└── doc/deckle.txt        :help
```

## 9. Distribuição

Seguindo o padrão do `blink.cmp`, que é o plugin Neovim com backend Rust mais instalado:

1. Baixa binário pré-compilado do GitHub Releases, verificando **checksum SHA-256**
2. Se não houver binário para a plataforma, cai para `cargo build --release`
3. Se as duas falharem, camada 0 — o plugin funciona sem mermaid renderizado

Matriz de CI: linux/macos/windows × x86_64/aarch64.

## 10. Riscos

| Risco | Gravidade | Mitigação |
|---|---|---|
| `merman` está em alpha e quebra API entre versões | alta | versão **pinada exata** (`=0.8.0-alpha.6`); binário pré-compilado isola o usuário |
| MSRV do merman é 1.95 (bem recente) | média | CI controla a toolchain; só afeta quem compila local |
| Bug de render no nó losango `{...}` | baixa | cosmético, reportar upstream |
| Diagrama grande custa ~46ms | média | debounce + cache por hash do bloco; render assíncrono |
| Sincronia de scroll em documento grande | média | mapa é O(blocos), busca binária O(log n) |
| Largura de emoji/CJK em tabelas | média | `vim.fn.strdisplaywidth`, nunca `#str` |

## 11. Fases

1. **Esqueleto**: buffer de preview, headings, parágrafos, listas, blockquote, wrap
2. **Sincronia de scroll** — antes de qualquer coisa bonita, senão o preview é inútil
3. **Tabelas** com largura de display correta
4. **Code blocks** com highlight via parser da linguagem (degrada se ausente)
5. **`deckle_native` + mermaid** — o ponto que diferencia o plugin
6. **Camada 2**: imagens via protocolo gráfico, com detecção

## 12. O que NÃO foi validado

Honestidade sobre os limites da validação:

- **Nada foi testado em Neovim 0.10.x.** Só existe 0.11.5 na máquina de teste. O piso de
  versão suportada é uma decisão em aberto, não um fato medido.
- **Nada foi testado em macOS ou Windows.** O `.so` do mlua carregou em Linux/glibc.
  macOS exige flags de link (`-undefined dynamic_lookup`) que não foram exercitadas.
- **Detecção de capacidade de terminal não foi implementada nem testada.** A tabela da
  seção 6 descreve um desenho, não algo medido.
- **A sincronia de scroll não tem protótipo.** É a parte de maior risco não validada.
- **O comportamento de `merman` sob entrada malformada não foi explorado a fundo** —
  testei o caminho feliz e o tipo não suportado, não fuzzing.
- **Cobertura real de cada um dos 14 tipos de diagrama foi auditada só no nível mínimo.**
  A fase 6 renderiza um diagrama mínimo de cada tipo (`cargo test`), o que prova que não
  quebra, não que o desenho está bom. Oito dos 14 saem como texto estruturado
  (`gantt`, `gitgraph`, `journey`, `kanban`, `mindmap`, `packet`, `timeline`, `treeView`),
  não como desenho: é a projeção primária deles no merman.
