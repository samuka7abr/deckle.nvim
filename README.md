# deckle.nvim

Preview de Markdown renderizado **dentro do Neovim**, num buffer separado somente-leitura.
Sem browser, sem servidor web, sem webview.

> **deckle** — na fabricação artesanal de papel, é a moldura removível que assenta sobre a
> forma e define as bordas da folha. A polpa disforme entra; a folha formada sai.

## Estado

Fase de desenho. Nada implementado ainda. A arquitetura foi validada empiricamente —
ver [`docs/validation.md`](docs/validation.md) para o que foi medido e o que ainda é suposição.

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
