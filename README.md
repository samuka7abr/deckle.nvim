# deckle.nvim

Preview de Markdown renderizado **dentro do Neovim**, num buffer separado somente-leitura.
Sem browser, sem servidor web, sem webview.

> **deckle** — na fabricação artesanal de papel, é a moldura removível que assenta sobre a
> forma e define as bordas da folha. A polpa disforme entra; a folha formada sai.

## Estado

**Fases 0, 1, 2, 3, 6 e 8 do [roadmap](docs/roadmap.md).** Existe o esqueleto — `:Deckle` com
subcomandos, configuração validada, `:checkhealth deckle`, suíte de testes e CI — o parser
(`lua/deckle/parse.lua`, Markdown para IR via treesitter, com a forma do IR documentada no
topo do módulo), o crate Rust `deckle-native`, a distribuição do binário dele (release por
plataforma, `:Deckle install`) e, desde a fase 2, o preview: `:Deckle open`
abre um buffer somente-leitura ao lado, com títulos, parágrafos com wrap por largura de
display (emoji e CJK incluídos), listas, citações e regras, re-renderizado com debounce quando
o fonte muda e quando a janela é redimensionada.

O preview acompanha o cursor do fonte e o inverso (`sync = "cursor"`, o default; `sync = "off"`
desliga). Tabelas, blocos de código e HTML saem como texto cru por enquanto (fases 4 e 5). Os
grupos de highlight (`DeckleH1` a `DeckleH6`, `DeckleCode`, `DeckleQuote` e outros, todos com
`default` e linkados a grupos padrão) podem ser sobrescritos com `vim.api.nvim_set_hl`; a lista
está em `lua/deckle/highlight.lua`.

A arquitetura foi validada empiricamente — ver [`docs/validation.md`](docs/validation.md)
para o que foi medido e o que ainda é suposição.

### Desenvolvimento

```sh
./scripts/test.sh                        # suíte inteira
./scripts/test.sh tests/test_config.lua  # um arquivo só
```

A primeira execução baixa o [mini.test](https://github.com/echasnovski/mini.nvim) em
`.deps/`. Formatação com `stylua`, lint com `selene`.

Os testes do parser comparam o IR de `tests/fixtures/*.md` com o snapshot ao lado
(`*.lua`). Depois de mudar o IR de propósito, regenere e **revise o diff** antes de commitar:

```sh
DECKLE_UPDATE_SNAPSHOTS=1 ./scripts/test.sh tests/test_parse.lua && stylua tests/
```

Componente nativo (Rust 1.95, instalado pelo `rustup` a partir do `rust-toolchain.toml`):

```sh
cargo test                  # lógica pura, sem Neovim: os 14 tipos de diagrama, erros, guardas
make native                 # compila e instala lua/deckle_native.<ext> (falha se o build falhar)
./scripts/test-native.sh    # make native + teste headless no nvim (exit 0 = sobreviveu)
make bench                  # benchmark do flowchart
make check-merman           # falha se o merman resolver para versão diferente da pinada
```

## Instalação

O plugin só precisa do Neovim 0.11 ou mais novo, e roda inteiro na camada 0. O binário
nativo (camada 1, o Mermaid renderizado) é opcional, e há dois jeitos de ter um.

### lazy.nvim

```lua
{
  "samuka7abr/deckle.nvim",
  cmd = "Deckle",
  -- Baixa o binário da release. Alternativa, que compila na hora e precisa de cargo e make:
  --   build = "make native",
  build = ":Deckle install",
  opts = {},
}
```

`:Deckle install` segue três degraus e o plugin funciona em qualquer um deles:

1. baixa `deckle_native-<alvo>.<ext>` da release `v<versão>` do GitHub (via `curl`), confere o
   SHA-256 do arquivo `.sha256` ao lado e instala;
2. se não há binário para a plataforma (ou não há rede), roda `cargo build --release` no
   próprio plugin. O `rustup` baixa a toolchain 1.95 sozinho, a partir do
   `rust-toolchain.toml`, e o `Cargo.lock` versionado mantém o merman na versão pinada;
3. se as duas falham, fica na camada 0: uma linha discreta no `:messages` e o motivo no
   `:checkhealth deckle`. Nenhum erro.

**Checksum errado é a exceção:** a instalação aborta e **não** tenta o cargo, porque um
binário que não bate com o hash publicado é um problema de integridade, não "não havia
binário". O plugin fica na camada 0 e o `:checkhealth deckle` mostra a divergência. O hash
vem do mesmo lugar que o binário, então isto protege de download corrompido e de CDN com
arquivo trocado, não de um repositório comprometido; não é assinatura.

O comando é assíncrono: o gerenciador considera o `build` concluído quando ele volta, e o
resultado chega por `vim.notify` e pelo checkhealth. Sem editor aberto (CI, Nix):

```sh
nvim --headless -c 'lua require("deckle.install").install(nil, function() vim.cmd("qa") end)'
```

### Onde o binário fica

Em `stdpath("data")/deckle/` (`~/.local/share/nvim/deckle/` no Linux), com um `install.json`
dizendo de onde veio (`release` ou `build`), para qual versão do plugin e o SHA-256. Não
dentro do diretório do plugin, porque o gerenciador o apaga e o recria (`lazy clean`,
reinstalação) ou o deixa somente-leitura (Nix), e porque assim o binário não suja o
checkout. O custo é que atualizar o plugin não atualiza o binário: o instalador compara a
versão gravada com `lua/deckle/version.lua` e um binário de outra versão conta como ausente.
Rode `:Deckle install` de novo depois de atualizar (o `build` do lazy faz isso sozinho).

O `make native` é o caminho de quem desenvolve: deixa `lua/deckle_native.<ext>` dentro do
plugin, que tem precedência sobre o diretório de dados.

### Alvos

| Alvo | Arquivo na release | Instalado como |
|---|---|---|
| `x86_64-unknown-linux-gnu` | `deckle_native-x86_64-unknown-linux-gnu.so` | `deckle_native.so` |
| `aarch64-unknown-linux-gnu` | `deckle_native-aarch64-unknown-linux-gnu.so` | `deckle_native.so` |
| `x86_64-apple-darwin` | `deckle_native-x86_64-apple-darwin.dylib` | `deckle_native.so` |
| `aarch64-apple-darwin` | `deckle_native-aarch64-apple-darwin.dylib` | `deckle_native.so` |
| `x86_64-pc-windows-msvc` | `deckle_native-x86_64-pc-windows-msvc.dll` | `deckle_native.dll` |
| `aarch64-pc-windows-msvc` | `deckle_native-aarch64-pc-windows-msvc.dll` | `deckle_native.dll` |

Linux com musl (Alpine) não tem binário: o `.so` de glibc não carrega lá, e o instalador vai
direto para o cargo.

## Como funciona

Lua faz tudo que encosta no Neovim: treesitter (parsers vêm do **core**, sem
nvim-treesitter), buffer de preview somente-leitura, extmarks, sincronia de scroll.

Um componente Rust opcional, carregado via `mlua`, cuida só do Mermaid — usando
[`merman`](https://crates.io/crates/merman-ascii), a implementação headless de Mermaid em
Rust que o Zed usa. Sem Node, sem Chromium, sem servidor web. 14 tipos de diagrama,
~1.4ms num flowchart típico.

Se esse binário não existir, o Mermaid degrada para bloco de código e o resto continua
funcionando.

```
┌───────┐     ┌──────┐
│ Alice │     │ John │
└───┬───┘     └───┬──┘
    │ Hello John  │
    ├────────────►│
    │ Great!      │
    │◄┈┈┈┈┈┈┈┈┈┈┈┈┤
```
<sub>saída real do renderer, medida — ver <a href="docs/validation.md">validation.md</a></sub>

## Princípios de projeto

1. **Zero dependência obrigatória.** Neovim e nada mais. Sem Node, sem ImageMagick,
   sem nvim-treesitter, sem outros plugins.
2. **Progressive enhancement.** Capacidades extras (protocolo gráfico do terminal, `mmdc`)
   são detectadas em runtime e melhoram o resultado. A ausência delas nunca quebra o plugin.
3. **Nada pode matar o editor.** Um diagrama malformado degrada aquele bloco, não a sessão.
4. **Degradação por feature.** Se o componente nativo não carregar, o mermaid vira bloco de
   código cru e todo o resto continua funcionando.

## Documentação

- [Arquitetura](docs/architecture.md)
- [Roadmap](docs/roadmap.md)
- [Validação empírica](docs/validation.md)
- Decisões (ADR):
  - [0001 — `mlua` em vez de `nvim-oxi`](docs/adr/0001-mlua-sobre-nvim-oxi.md)
  - [0002 — `merman-ascii` em vez de implementar Mermaid do zero](docs/adr/0002-merman-sobre-implementacao-propria.md)
  - [0003 — buffer separado, não decoração in-place](docs/adr/0003-buffer-separado.md)
  - [0004 — degradação em camadas](docs/adr/0004-degradacao-em-camadas.md)
