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

## Versão escolhida (fase 6, reconferida em 2026-11-17)

**`merman-core` e `merman-ascii` em `=0.8.0-alpha.6`.** É a versão em que V5 foi medido, e
tudo o que a fase 6 prova (os 14 tipos, o benchmark) vale para ela.

A reconferência na crates.io mostrou que o merman andou desde a validação: já existem
`0.8.0` e `0.10.0` (sem sufixo alpha; a `0.10.0` declara MSRV 1.95). Não subimos nesta fase
por duas razões: a API quebra entre versões, então subir exige reler `render_model_report` e
revalidar tipo por tipo; e a fase 6 é "isolar o crate", não "atualizar o merman". Subir
vira PR próprio, que reroda `cargo test` (os 14 tipos), o benchmark e atualiza este ADR.

O pin vive em quatro lugares que andam juntos: `crates/deckle-native/Cargo.toml`,
`scripts/check-merman-version.sh`, este ADR e o `CLAUDE.md`. A CI roda o script, que lê o
que o cargo **resolveu** (não o que o `Cargo.toml` pede) e falha se for diferente.

Decisões de uso da API que a fase 6 tomou, para o próximo que for subir a versão:

- Entra por `Engine::parse_diagram_for_render_model_sync` (ou `..._with_type_sync` quando o
  chamador informa `diagram_ty`) e `AsciiRenderer::render_model_report`. O `README` do
  `merman-ascii` recomenda a fachada `merman` com a feature `ascii`; ficamos nos dois crates
  separados porque o roadmap pina os dois.
- `OverflowPolicy::Fallback` **não é usado**. Medido: um xychart de duas barras, com
  largura 120, saiu como um dump `model.plots[0].data[0][0]: "a"`, em vez do gráfico. O
  README do `merman-ascii` diz que o fallback do flowchart é uma projeção JSON tipada.
  Usamos `Allow` e, se estourar, tentamos o perfil `Compact` (que só flowchart e sequence
  aceitam). Se ainda passar, a linha larga é devolvida inteira: o merman nunca trunca.
- Contexto de operação determinístico (`RuntimePolicy::deterministic`), com relógio fixo:
  diagramas que dependem da data de hoje, como o `gantt`, não enxergam a data real.
