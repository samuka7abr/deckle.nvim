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

O render é `render(ir, { width, charset }) -> { lines, marks, map }`, função pura que não toca
em buffer nem em janela (quem escreve é `preview.lua`). Um módulo por tipo de bloco recebe
`(block, ctx)` e devolve `lines, marks`; contêineres (`quote`, `list`) renderizam os filhos
numa largura menor e prefixam as linhas. O contrato completo está em LuaCATS no topo de
`lua/deckle/render/init.lua`.

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

native.supported_types()  -- string[]: os 15 tipos do renderer de texto, lidos do merman
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

Na fase 9 a camada 2 passou a existir para o protocolo do kitty (também o do ghostty): `caps.lua`
detecta (na dúvida, sem gráfico: tmux sem `allow-passthrough` confirmado, SSH e terminal burro
ficam em texto) e `image/` desenha por Unicode placeholders, de modo que a imagem rola com o
buffer sem nenhum código de reposicionamento. iTerm2 e sixel são detectados e seguem em texto
alternativo. O detalhe e o que não foi medido estão no roadmap (fase 9) e na seção 12.

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
│   ├── render/           IR → linhas + marcas + mapa (um módulo por tipo de bloco)
│   ├── preview.lua       janela, buffer, extmarks, re-render com debounce
│   ├── highlight.lua     grupos DeckleH1..H6, DeckleCode, DeckleQuote... (default, linkados)
│   ├── sync.lua          scroll sync
│   ├── native.lua        carrega o .so, degrada se ausente
│   ├── install.lua       baixa/compila o .so, confere SHA-256, registra a origem
│   ├── sha256.lua        SHA-256 em Lua puro (vim.fn.sha256 não serve para binário)
│   ├── version.lua       versão do plugin: monta a URL da release
│   ├── caps.lua          detecção de capacidade de terminal (pura, sobre uma tabela de ambiente)
│   ├── image/            imagens da camada 2: estado e escrita (init), protocolo kitty, cabeçalho PNG
│   └── health.lua        :checkhealth deckle
├── crates/deckle-native/ cdylib mlua → merman
├── doc/deckle.txt        :help, escrito à mão; a suíte o confere contra o código
└── examples/showcase.md  teste manual com todo tipo de bloco; a suíte o renderiza
```

## 9. Distribuição

Seguindo o padrão do `blink.cmp`, que é o plugin Neovim com backend Rust mais instalado:

1. Baixa binário pré-compilado do GitHub Releases, verificando **checksum SHA-256**
2. Se não houver binário para a plataforma, cai para `cargo build --release`
3. Se as duas falharem, camada 0 — o plugin funciona sem mermaid renderizado

Matriz de CI: linux/macos/windows × x86_64/aarch64.

Como ficou na fase 8:

- **Release.** `.github/workflows/release.yml` compila o cdylib nos seis alvos, em runner
  nativo quando existe, e publica `deckle_native-<alvo>.<so|dylib|dll>` mais um `.sha256` por
  arquivo (formato do `sha256sum`). Antes de subir, cada runner nativo instala o artefato pelo
  instalador de verdade e roda a bateria de `tests/native/native_headless.lua` nele. Só
  tag `v*` publica; `workflow_dispatch` e PR deixam os artefatos no workflow.
- **Versão.** `lua/deckle/version.lua` é a fonte; a URL é `.../releases/download/v<versão>/`.
  A CI recusa uma tag que não bate (`v0.2.0-rc` vale para `0.2.0`).
- **Instalador.** `lua/deckle/install.lua`: detecta o alvo por `jit.arch` (a arquitetura do
  processo, que é o que o `dlopen` exige) e `uv.os_uname()`, baixa com `curl` por
  `vim.system`, confere o SHA-256 (`lua/deckle/sha256.lua`, Lua puro: `vim.fn.sha256`
  responde `E976` a binário com NUL), instala por `rename` e registra a origem em
  `install.json`. Sem binário, `cargo build --release --locked`; sem cargo, camada 0.
  **Checksum que não bate aborta sem tentar o cargo.**
- **Onde fica.** `stdpath("data")/deckle/deckle_native.<so|dll>`, não dentro do plugin: o
  gerenciador apaga e recria o diretório do plugin, e Nix o deixa somente-leitura. No macOS
  o `.dylib` da release é instalado como `deckle_native.so`, porque o `package.cpath` do
  LuaJIT não procura `.dylib`. O `make native` deixa o binário em `lua/` e tem precedência.
- **Contrato com a fase 7.** `require("deckle.install").info()` devolve
  `{ origin = "release" | "build" | "missing", path, version, target, source, reason,
  last_error }`, só lendo o disco. Um binário de versão diferente da do plugin conta como
  `missing`. Carregar é `package.loadlib(info.path, "luaopen_deckle_native")`.

## 10. Riscos

| Risco | Gravidade | Mitigação |
|---|---|---|
| `merman` quebra API entre versões | alta | versão **pinada exata** (`=0.8.0`, com `all-diagrams`); binário pré-compilado isola o usuário |
| MSRV do merman é 1.95 (bem recente) | média | CI controla a toolchain; só afeta quem compila local |
| Bug de render no nó losango `{...}` | baixa | cosmético, reportar upstream |
| Diagrama grande custa ~46ms | média | debounce + cache por hash do bloco; render assíncrono |
| Sincronia de scroll em documento grande | média | mapa é O(blocos), busca binária O(log n) |
| Largura de emoji/CJK em tabelas | média | `vim.api.nvim_strwidth` nas tabelas e `vim.fn.strdisplaywidth` no resto, nunca `#str` (ver a regra 6 do `CLAUDE.md`) |

## 11. Fases

1. **Esqueleto**: buffer de preview, headings, parágrafos, listas, blockquote, wrap
2. **Sincronia de scroll** — antes de qualquer coisa bonita, senão o preview é inútil
3. **Tabelas** com largura de display correta
4. **Code blocks** com highlight via parser da linguagem (degrada se ausente)
5. **`deckle_native` + mermaid** — o ponto que diferencia o plugin
6. **Camada 2**: imagens via protocolo gráfico, com detecção

## 12. O que NÃO foi validado

Honestidade sobre os limites da validação:

- **Piso de versão: medido na fase 0, decidido no [ADR-0005](adr/0005-piso-neovim-0-11.md).**
  O Neovim 0.10.4 reprovou na CI (20 dos 39 casos), e o piso é 0.11.0. Foram exercitadas a
  0.11.0 (CI), a 0.11.5 (máquina de desenvolvimento) e o nightly (CI). **Não foi exercitado:** o
  Neovim entre 0.11.1 e 0.11.4 e qualquer estável acima da 0.11.5.
- **macOS e Windows: medido na fase 8, com limites.** O módulo compila, é instalado pelo
  instalador e carrega, com a bateria de `native_headless.lua`, num Neovim **0.11.0** em Linux
  x86_64 e aarch64 (glibc), macOS x86_64 e arm64 (com `-undefined dynamic_lookup`) e Windows
  x86_64 (V9). **Não foi exercitado:** o Windows aarch64, que só é cross-compilado (nenhum
  runner o executa, e não há Neovim aarch64 para Windows); musl (cai para o cargo, sem teste de
  build em Alpine); qualquer Neovim diferente do 0.11.0 nesses sistemas; e a publicação em si
  (`softprops/action-gh-release`), que só roda em tag.
- **Detecção de capacidade de terminal: implementada na fase 9 (`lua/deckle/caps.lua`) e
  testada com ambientes forjados** (kitty, ghostty, WezTerm, iTerm2, sixel, tmux mentindo, SSH,
  GNU screen, terminal burro), e a consulta do `allow-passthrough` do tmux com um `tmux` falso no
  PATH. **Não foi medida em terminal real nem em tmux real.** As variáveis que ela lê
  (`KITTY_WINDOW_ID`, `GHOSTTY_*`, `WEZTERM_*`, `LC_TERMINAL`...) são as que cada terminal
  documenta, mas dentro do tmux podem estar velhas (o tmux guarda o ambiente de quem o iniciou),
  e é por isso que a detecção só confia nelas com `allow-passthrough` confirmado.
- **As imagens (camada 2) só foram verificadas até o tty.** Só o protocolo do kitty é desenhado
  (Unicode placeholders). Num Neovim com TUI dentro de um pty, o plugin escreve os escapes
  certos e o Neovim emite as células de placeholder com o id na cor. **Nenhum terminal gráfico de
  verdade abriu uma imagem do deckle**: kitty, ghostty e o repasse do tmux estão sem medida, e a
  proporção depende de uma célula suposta de 10 x 20 pixels. iTerm2 e sixel são detectados e
  caem em texto alternativo.
- **A sincronia de scroll foi implementada na fase 3** e testada em Neovim headless, com teclas
  reais enviadas por RPC. **Não foi vista numa UI de terminal de verdade**, nem com `wrap`
  ligado, dobras e `scrolloff` alto no fonte, nem pela roda do mouse.
- **O comportamento de `merman` sob entrada malformada não foi explorado a fundo** —
  testei o caminho feliz e o tipo não suportado, não fuzzing.
- **Cobertura real de cada um dos 14 tipos de diagrama foi auditada só no nível mínimo.**
  A fase 6 renderiza um diagrama mínimo de cada tipo (`cargo test`), o que prova que não
  quebra, não que o desenho está bom. Oito dos 14 saem como texto estruturado
  (`gantt`, `gitgraph`, `journey`, `kanban`, `mindmap`, `packet`, `timeline`, `treeView`),
  não como desenho: é a projeção primária deles no merman.
