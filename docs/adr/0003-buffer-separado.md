# ADR-0003 — Buffer separado somente-leitura, não decoração in-place

**Status:** aceito · **Data:** 2026-09-06

## Contexto

Há dois modelos de preview de Markdown dentro do editor:

1. **Decoração in-place** — `markview.nvim`, `render-markdown.nvim`. Extmarks e conceal
   embelezam o próprio buffer editável.
2. **Buffer separado** — o painel de preview do Zed. Um segundo buffer, somente-leitura,
   com o resultado renderizado.

O ecossistema Neovim foi quase inteiro para o modelo 1.

## Decisão

Buffer separado, `nomodifiable`, em split.

## Razão

O modelo 1 é prisioneiro do texto original: o render precisa caber, mais ou menos, nas
mesmas linhas que o fonte ocupa. Um bloco mermaid de 6 linhas que vira um diagrama de 40
só existe ali como `virt_lines` penduradas, e qualquer reflow de parágrafo é impossível.

Como o mermaid renderizado é a razão de ser do deckle, essa limitação é fatal para o
modelo 1 e irrelevante para o modelo 2.

Ganhos adicionais do buffer separado: liberdade de reordenar (índice, notas de rodapé no
fim), de aplicar wrap próprio na largura da janela, e de manter o buffer fonte
completamente intocado — nenhum extmark, nenhum conceal, nenhuma interferência com outros
plugins que decorem o mesmo buffer.

## Consequências

- **Sincronia de scroll passa a ser problema nosso.** É o custo principal, e não tem
  solução pronta no ecossistema. Ver seção 7 da [arquitetura](../architecture.md).
- Não dá para editar vendo o resultado ao vivo lado a lado no mesmo texto — quem quer
  isso é melhor servido por `markview.nvim`, e tudo bem.
- Duas janelas ocupam espaço. O preview precisa ser fácil de abrir e fechar.
- O highlight de code block precisa ser refeito à mão no buffer de preview, já que ele
  não tem mais `filetype=markdown` para as injeções do treesitter funcionarem sozinhas.
