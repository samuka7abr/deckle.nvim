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

- **`merman` quebra API entre versões.** Era alpha (`0.8.0-alpha.6`) quando este ADR foi
  escrito, e a `0.10.0`, já estável, mexeu na API de novo (ver "Versão escolhida"). Mitigação:
  versão pinada exata nos três crates, e o binário pré-compilado isola o usuário final de
  qualquer churn.
- **MSRV 1.95**, bem recente. Afeta apenas quem compila localmente; a CI controla a
  toolchain. Com rustc mais antigo o cargo resolvia silenciosamente para um alpha velho
  e pior — o build precisa falhar explicitamente nesse caso.
- **`merman-core`, `merman-ascii` e `merman-model` precisam de versão idêntica.**
- Bugs de render existem (ver [V5](../validation.md#bug-encontrado--nó-losango)).
  São cosméticos; a saída degrada em legibilidade, não em corretude.
- **O layout de texto não roteia todo flowchart nem todo `state`** (ver
  [V5b](../validation.md#v5b--onde-o-layout-de-texto-do-merman-para-e-o-que-a-0100-muda)).
  Aresta que cruza a borda de um subgraph, arestas de traços diferentes que se cruzam e
  estado composto fora da forma mais simples devolvem erro em **toda** versão medida. Para o
  flowchart o crate tem um degrau de simplificação; o resto está em "Limitações conhecidas".
- Ficamos dependentes de um projeto de terceiros para a feature central. É a troca
  consciente: entregar em semanas com bugs cosméticos alheios em vez de em meses com
  bugs próprios.

## Versão escolhida (atualizada em 2026-11-18)

**`merman-core`, `merman-ascii` e `merman-model` em `=0.10.0`**, a versão estável mais
recente da crates.io. Foi a que a correção do bug "flowchart real não renderiza" mediu, e a
que o `cargo test` (os 14 tipos, o showcase `examples/mermaid.md`) e o benchmark cobrem.

Por que subir da `0.8.0-alpha.6` (medido, ver [V5b](../validation.md#v5b--onde-o-layout-de-texto-do-merman-para-e-o-que-a-0100-muda)):

- **Nenhuma das duas versões renderiza o diagrama do bug** (o `flowchart TB` de arquitetura do
  README do ILZA, com subgraphs aninhados de `direction` diferente, e o `graph LR` com
  subgraphs). Nem o perfil compacto, nem o `Auto`, nem teto de trabalho maior, nem
  espaçamento de grafo maior, nem tirar os `direction`, nem achatar só os subgraphs aninhados.
  A causa é o layout de texto, não uma opção: a aresta que cruza a borda de um grupo não tem
  rota.
- A `0.10.0` roteia mais: cada uma das 26 linhas de aresta do diagrama de arquitetura renderiza
  **sozinha** (a alpha reprova 5), aceita genéricos com vírgula na `classDiagram`
  (`Cache~K, V~`, que a alpha recusa com `Unexpected character`), e o benchmark do flowchart
  grande cai (V5b). Ela regride numa coisa: sozinha, a cadeia `A_PRES --> A_APP --> A_DOMAIN` do
  `graph LR` do ILZA, dentro de subgraphs aninhados com `direction`, que a alpha desenha (o
  diagrama inteiro falhava igual nas duas).
- Sem sufixo alpha, e a API da `0.10.0` é a que o upstream documenta.

A solução do bug **não** é a versão: é o degrau de simplificação do crate (`render.rs`, "Degrau
de simplificação"), que desenha o flowchart sem o que o layout não sabe rotear e avisa.

O pin vive em quatro lugares que andam juntos: `crates/deckle-native/Cargo.toml` (os **três**
crates), `scripts/check-merman-version.sh`, este ADR e o `CLAUDE.md`. A CI roda o script, que
lê o que o cargo **resolveu** (não o que o `Cargo.toml` pede) e falha se for diferente, e
confere também que nenhum outro crate `merman-*` entrou em versão diferente.

Decisões de uso da API, para o próximo que for subir a versão:

- Entra por `SemanticParser` (`parse_diagram_with_options_controlled_in_context_sync`, ou
  `parse_diagram_with_type_controlled_sync` quando o chamador informa `diagram_ty`) e
  `AsciiRenderer::render_parsed_report`. O `README` do `merman-ascii` recomenda a fachada
  `merman` com a feature `ascii`; ficamos nos crates separados porque o roadmap os pina.
- **O `OperationControl` mora no `merman-model` e a `0.10.0` não o reexporta** (o README do
  `merman-ascii` importa de `merman_core`, e isso não compila). Por isso `merman-model` é
  dependência direta, pinada junto.
- **Nenhuma família vem por padrão.** `merman-core` entra com `all-diagrams` (todo tipo do
  Mermaid parseia, e um `pie` cai em "unsupported diagram", não em erro de sintaxe) e
  `merman-ascii` com as 14 famílias do renderer de texto, uma a uma. `diagram-swimlane` fica de
  fora de propósito: com `all-diagrams` no `merman-ascii` o `supported_types()` passa a ter 15
  tipos, e o plugin documenta 14.
- `OverflowPolicy::Fallback` **não é usado**. Medido na fase 6: um xychart de duas barras, com
  largura 120, saiu como um dump `model.plots[0].data[0][0]: "a"`, em vez do gráfico. O
  README do `merman-ascii` diz que o fallback do flowchart é uma projeção JSON tipada.
  Usamos `Allow` e, se estourar, tentamos o perfil `Compact` (que só flowchart e sequence
  aceitam). O perfil `Auto` da `0.10.0` faz o mesmo para essas duas famílias (a doc dele diz
  que só elas o admitem); ficamos com a tentativa explícita, que vale nas duas versões e
  ignora o erro de admissão das outras famílias. Se ainda passar, a linha larga é devolvida
  inteira: o merman nunca trunca.
- Contexto de operação determinístico (`SemanticParser::begin_operation`, política
  `deterministic`), com relógio fixo: diagramas que dependem da data de hoje, como o `gantt`,
  não enxergam a data real.
- **Teto de trabalho de layout em 4 000 000** (o perfil `interactive` do merman para em
  2 000 000), por `AsciiResourcePolicy::with_limit(MaxLayoutWorkUnits, ...)`. Medido: o diagrama
  de arquitetura do ILZA, achatado, passa de 2 milhões (reprova com 2, desenha com 4, em 29
  ms), e um flowchart em camadas de 56 nós e 77 arestas também. O pior caso (o merman gasta o
  teto inteiro procurando rota que não existe) custa cerca de 40 ms em release com 4 milhões,
  20 ms com 2. Subir mais não ajuda: os diagramas que ainda falham gastam o teto que houver
  (medido até 20 milhões).
- **Degrau de simplificação do flowchart** (`Rendered::notice`): se o diagrama como escrito dá
  `UnsupportedFeature` ou estoura um limite de recurso, o crate reparseia e tenta de novo,
  nesta ordem, sem o traço das arestas, sem as bordas dos subgraphs e sem os dois. O que o
  layout não roteia some; nenhum nó e nenhuma aresta some. Se nada desenha, o erro é o do
  diagrama original. Só o flowchart: o modelo de `state` é uma árvore de documentos, e achatá-la
  mudaria o significado dos `[*]`.

A `0.8.0` estável (sem sufixo) não foi medida: o crate não parseia flowchart com as features
padrão dela, e a `0.10.0` já resolve a pergunta que importava (subir ou não). Fica registrado
como não validado.

### Histórico: a versão da fase 6 (2026-11-17)

A fase 6 ficou em `=0.8.0-alpha.6`, a versão em que V5 foi medido. A reconferência na
crates.io mostrou `0.8.0` e `0.10.0`, e a subida ficou para um PR próprio, que reroda `cargo
test` (os 14 tipos), o benchmark e atualiza este ADR: é o PR que escreveu a seção acima.
