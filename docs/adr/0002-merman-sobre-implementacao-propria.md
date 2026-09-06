# ADR-0002 — Usar `merman-ascii` em vez de implementar Mermaid do zero

**Status:** aceito · **Data:** 2026-09-06

## Contexto

Renderizar Mermaid em grid de caracteres era, no desenho original, o núcleo do projeto e
sua maior dificuldade. Escrever isso do zero significa: um lexer/parser por tipo de
diagrama (o Mermaid tem 30+ tipos e **não possui gramática formal publicada** — a
migração de Jison para Langium está em andamento e incompleta), o pipeline de Sugiyama
completo (remoção de ciclos, ranking, minimização de cruzamentos, atribuição de
coordenadas por Brandes-Köpf) e roteamento ortogonal de arestas em células de terminal.

Estimativa realista: meses para cobrir flowchart e sequence, os dois tipos mais usados.

## Decisão

Usar o crate **`merman-ascii`** (com `merman-core`), versão **pinada exata**.

## Razão

`merman` é uma reimplementação headless do Mermaid em Rust, sem Node, Puppeteer ou
Chromium — e é o backend de Mermaid usado pelo **Zed**, que é justamente a referência
de UX deste projeto.

Medido em [V5](../validation.md#v5--merman-ascii-renderiza-mermaid-sem-node-nem-chromium):

- **14 tipos de diagrama** suportados pelo renderer ASCII, confirmados em runtime via
  `ascii_supported_diagram_types()` — não por README.
- Saída de `sequenceDiagram` e `classDiagram` de qualidade publicável.
- **1.42ms** num flowchart típico. Serve para preview ao vivo.
- Charset ASCII puro disponível para terminais sem Unicode.
- A doc do próprio crate nomeia este caso de uso: *"the preferred entrypoint for Markdown
  renderers and editors that already know the diagram type from the code fence info string"*.

Isso remove a parte mais difícil do projeto e o reduz a: renderizador de Markdown em Lua
+ binding fino. Um projeto de semanas, não de meses.

## Alternativas descartadas

- **Implementação própria com `rust-sugiyama` + `ascii-dag`.** Ambos existem, são bons
  (`ascii-dag` já faz Sugiyama com roteamento ortogonal para terminal), mas resolvem
  layout de grafo — não o parsing de 30 tipos de diagrama Mermaid, que é o grosso do
  trabalho. Ficam como plano B caso o `merman` seja abandonado.
- **Shell out para `mmdc`.** Arrasta Node + Chromium (~300MB), é lento no primeiro render
  e produz imagem, que exige protocolo gráfico do terminal. Viola o princípio de zero
  dependência obrigatória. Fica como camada 3 opcional.
- **`mermaid-ascii` (Go).** Cobre só 3 famílias de diagrama e exigiria um subprocesso.

## Consequências e riscos aceitos

- **`merman` está em alpha** (`0.8.0-alpha.6`) e quebra API entre versões — confirmado
  entre 0.7 e 0.8. Mitigação: versão pinada exata, e o binário pré-compilado isola o
  usuário final de qualquer churn.
- **MSRV 1.95**, bem recente. Afeta apenas quem compila localmente; a CI controla a
  toolchain. Com rustc mais antigo o cargo resolve silenciosamente para um alpha velho
  e pior — o build precisa falhar explicitamente nesse caso.
- **`merman-core` e `merman-ascii` precisam de versão idêntica.**
- Bugs de render existem (ver [V5](../validation.md#bug-encontrado--nó-losango)).
  São cosméticos; a saída degrada em legibilidade, não em corretude.
- Ficamos dependentes de um projeto de terceiros para a feature central. É a troca
  consciente: entregar em semanas com bugs cosméticos alheios em vez de em meses com
  bugs próprios.
