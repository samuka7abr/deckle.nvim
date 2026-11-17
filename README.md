# deckle.nvim

Preview de Markdown renderizado **dentro do Neovim**, num buffer separado somente-leitura.
Sem browser, sem servidor web, sem webview.

> **deckle** — na fabricação artesanal de papel, é a moldura removível que assenta sobre a
> forma e define as bordas da folha. A polpa disforme entra; a folha formada sai.

## Estado

**Fases 0, 1 e 6 do [roadmap](docs/roadmap.md).** Existe o esqueleto — `:Deckle` com
subcomandos, configuração validada, `:checkhealth deckle`, suíte de testes e CI — mais o
parser (`lua/deckle/parse.lua`, Markdown para IR via treesitter, com a forma do IR
documentada no topo do módulo) e o crate Rust `deckle-native`. Ainda não existe render:
`:Deckle open` avisa que o preview chega na fase 2.

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
make native                 # compila e instala lua/deckle_native.so (falha se o build falhar)
./scripts/test-native.sh    # make native + teste headless no nvim (exit 0 = sobreviveu)
make bench                  # benchmark do flowchart
make check-merman           # falha se o merman resolver para versão diferente da pinada
```

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
