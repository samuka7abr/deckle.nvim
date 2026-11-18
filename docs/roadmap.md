# Roadmap

Este documento substitui a seção 11 da [arquitetura](architecture.md), que lista as fases
em uma linha cada. Aqui cada fase tem entrega, arquivos, gate de saída e anti-escopo.

Uma fase = um PR. Se um PR não passar no gate da própria fase, ele não entra.

## Convenções

- Branch: `feat/f<N>-<slug>` a partir da `main`.
- Commits: Angular/Conventional, atômicos, sem corpo e sem co-autor.
- PR: título igual ao nome da fase, descrição com o gate de saída marcado.
- Toda fase entra com teste. Fase sem teste é fase não terminada.
- Todo caminho de degradação citado em ADR-0004 precisa de um teste que force a
  degradação, não de um comentário dizendo que funciona.

## Decisões tomadas para destravar a fase 0

Estão aqui para serem contestadas antes de virarem código. Só o piso de Neovim virou ADR
([ADR-0005](adr/0005-piso-neovim-0-11.md), na fase 10); as demais seguem só aqui.

| Decisão | Escolha | Por quê |
|---|---|---|
| Piso de Neovim | **0.11.0** | é a única versão medida (V1, V2, V3). O 0.10 foi à CI como job permissivo e reprovou; o piso fica onde está |
| Framework de teste | **mini.test** | roda em `nvim --headless`, é Lua puro, não precisa de luarocks nem busted (nenhum dos dois está instalado). Dependência só de desenvolvimento |
| Formatação | **stylua** | já existe na máquina via mason |
| Lint | **selene** em vez de luacheck | selene tem binário estático, luacheck arrasta luarocks |
| Toolchain Rust | `rust-toolchain.toml` pinado em **1.95** | o default local é 1.93, e com 1.93 o cargo resolve merman para `0.7.0-alpha.1` sem avisar |
| Índices de linha | **0-indexado, fim exclusivo** em todo o IR | é o que o treesitter e a API de buffer do Neovim usam. Converter nas bordas, nunca no meio |

## Visão geral

| Fase | PR | Entrega | Camada | Tag |
|---|---|---|---|---|
| 0 | 1 | esqueleto, config, comandos, CI, checkhealth | 0 | |
| 1 | 2 | `parse.lua`: treesitter → IR | 0 | |
| 2 | 3 | render de texto + buffer de preview | 0 | |
| 3 | 4 | sincronia de scroll | 0 | |
| 4 | 5 | tabelas com largura de display | 0 | |
| 5 | 6 | code blocks com highlight por linguagem | 0 | **v0.1.0** |
| 6 | 7 | crate `deckle-native` (Rust isolado) | 1 | |
| 7 | 8 | integração mermaid no Lua, cache, degradação | 1 | |
| 8 | 9 | distribuição: matriz de CI, releases, instalador | 1 | **v0.2.0** |
| 9 | 10 | `caps.lua` e imagens via protocolo gráfico | 2 | |
| 10 | 11 | `doc/deckle.txt`, polimento, exemplos | 2 | **v0.3.0** |

A v0.1.0 é um plugin útil e completo sem uma linha de Rust. Isso é de propósito: valida a
camada 0 de ADR-0004 na prática antes de qualquer binário existir.

---

## Fase 0 — Fundação

Nada de render. O objetivo é ter onde encostar as próximas fases e um gate de CI que
falhe de verdade.

**Entrega**

- `plugin/deckle.lua`: registra `:Deckle` e sai. Sem carregar o resto.
- `lua/deckle/init.lua`: `setup(opts)`, despacho dos subcomandos, completion.
- `lua/deckle/config.lua`: defaults e validação com `vim.validate`.
- `lua/deckle/health.lua`: `:checkhealth deckle` dizendo versão do Neovim, presença dos
  parsers `markdown` e `markdown_inline`, e a camada atual (0, sempre, nesta fase).
- `tests/` com mini.test, `scripts/test.sh` baixando as dependências de dev em `.deps/`.
- `.github/workflows/ci.yml`: stylua, selene, testes em Neovim 0.11 e nightly.

Subcomandos: `open`, `close`, `toggle`, `refresh`, `health`.

Defaults propostos:

```lua
{
  split       = "vsplit",   -- "vsplit" | "split" | "tab"
  width       = nil,        -- nil = largura da janela
  charset     = "auto",     -- "auto" | "unicode" | "ascii"
  sync        = "cursor",   -- "cursor" | "off"
  debounce_ms = 120,
  native      = { enabled = true, path = nil },
  mermaid     = { max_src_lines = 200 },
}
```

**Gate de saída**

1. `./scripts/test.sh` verde em `nvim --headless`, com exit code diferente de zero
   quando um teste falha. Testar isso quebrando um teste de propósito.
2. `:checkhealth deckle` roda e informa a camada.
3. `require('deckle')` não custa nada até `setup()` ser chamado.

**Anti-escopo:** nenhum parsing, nenhum buffer de preview.

**Risco:** o gate 1 é o que costuma nascer quebrado. Um harness que retorna 0 com teste
falhando torna todas as fases seguintes inúteis. É a primeira coisa a verificar.

---

## Fase 1 — `parse.lua`: fonte para IR

Treesitter entra, lista plana de blocos sai. Sem tocar em janela nem em buffer de saída.

**Entrega**

Blocos: `heading`, `paragraph`, `list`, `code`, `quote`, `table`, `rule`, `html`.
Cada bloco carrega `src_start` e `src_end`, que é o que alimenta a fase 3.

Spans de `markdown_inline` dentro de cada bloco de texto: `strong`, `emphasis`, `code`,
`link` (com `href`), `image` (com `alt` e `src`), `text`.

Forma do IR:

```lua
{ kind = "heading",   level = 2, spans = {...}, src_start = 4, src_end = 5 }
{ kind = "paragraph", spans = {...},            src_start = 6, src_end = 9 }
{ kind = "code",      lang = "rust", lines = {...}, src_start, src_end }
{ kind = "list",      ordered = false, items = { { spans, children } }, ... }
```

Bloco desconhecido vira `paragraph` com o texto cru. O parser nunca lança.

**Gate de saída**

1. Fixtures em `tests/fixtures/*.md` com IR esperado em snapshot.
2. Um documento com aninhamento patológico (lista dentro de quote dentro de lista) parseia
   sem estourar a pilha.
3. Arquivo vazio e arquivo de uma linha só produzem IR válido.
4. `src_start` e `src_end` de todo bloco batem com o texto real do fonte, verificado por
   teste que recorta o buffer pelas linhas e compara.

**Anti-escopo:** render, largura, wrap.

**Risco:** o gate 4 é chato de escrever e é exatamente o que impede a fase 3 de virar
caça a off-by-one.

**Entregue.** A forma final do IR está em LuaCATS no topo de `lua/deckle/parse.lua`; é a
referência das fases 2 a 5, não o esboço acima. O que difere dele ou vai além:

- Span `break` (quebra forçada de linha), que o esboço não tinha. Sem ele o render não
  distingue quebra suave de forçada. Quebra suave é `"\n"` dentro de `text`.
- `strong`, `emphasis` e `link` aninham por `children`; `image.alt` é texto simples.
- Item de lista tem `src_start`/`src_end` próprios, e `checked` em item de tarefa.
- `table` carrega `header`, `rows` (não normalizadas) e `align`, que tem buracos: use
  `#header` para o número de colunas.
- Link de referência é resolvido pela definição do documento, e a definição (`[r]: url`) não
  gera bloco.
- Front matter e qualquer nó que o treesitter não entenda (`ERROR` inclusive) viram `paragraph`
  cru. Tachado, entidades e HTML inline passam crus dentro de `text`.
- `src_end` nunca inclui linha em branco final, e o saneamento final garante irmãos em ordem
  e filhos dentro do pai, mesmo com árvore quebrada.
- **Guarda de aninhamento.** O scanner de Markdown aborta o processo com ~200 contêineres
  abertos (V6 em `docs/validation.md`). Acima de `MAX_NESTING` o documento inteiro cai no
  caminho cru, e acima de `MAX_DEPTH` só o contêiner fundo demais.

---

## Fase 2 — Render de texto e buffer de preview

Primeira fase com resultado visível.

**Entrega**

- `lua/deckle/render/` com um módulo por tipo: `heading`, `paragraph`, `list`, `quote`,
  `rule`. Cada um recebe um bloco e a largura, devolve linhas e marcas.
- Wrap por `vim.fn.strdisplaywidth`, nunca por `#str`. Emoji e CJK entram no teste desde já.
- `lua/deckle/preview.lua`: buffer scratch `nomodifiable`, split, reuso do buffer entre
  aberturas, extmarks para os highlights, grupos `DeckleH1..H6`, `DeckleCode`, `DeckleQuote`,
  todos com `default` e linkados a grupos padrão.
- Re-render com debounce em `TextChanged` e `InsertLeave` do buffer fonte.

O render já emite o mapa `linha_do_preview → linha_do_fonte` nesta fase, mesmo sem
ninguém consumir. A fase 3 só consome.

Contrato: `render(ir, opts) -> { lines, marks, map }`.

**Gate de saída**

1. Abrir o `README.md` do próprio projeto com `:Deckle open` e ver o resultado.
2. O buffer de preview rejeita edição.
3. Fechar e reabrir não vaza buffer nem autocmd, verificado por contagem.
4. Teste de wrap com linha de emoji e linha de CJK.
5. O buffer fonte termina o teste sem nenhum extmark do deckle. Ele é intocado por ADR-0003.

**Anti-escopo:** tabelas, code blocks com cor, scroll sync.

**Entregue.** O contrato do render (módulo por tipo, `ctx`, marcas, mapa) está em LuaCATS no
topo de `lua/deckle/render/init.lua`, e o do buffer de preview (ciclo de vida, eventos,
`state()`) no topo de `lua/deckle/preview.lua`: são a referência das fases 3, 4, 5 e 7. O que
difere do esboço acima ou vai além:

- **Contrato do módulo por tipo:** `lua/deckle/render/<kind>.lua` devolve `{ render = fn }`, com
  `fn(block, ctx) -> lines, marks`. `ctx` é `{ width, charset, indent, depth, block }`:
  `width` já descontado o prefixo dos contêineres, `charset` já resolvido (nunca `"auto"`),
  `indent` e `depth` informativos, e `ctx.block(child, consumed, extra)` renderiza um filho
  numa largura menor. Recuo e borda são do contêiner (`quote`, `list`), não do módulo.
- **Marcas** são `{ row, col, end_col, hl }`, com `col` e `end_col` em **bytes**
  0-indexados (fim exclusivo), o que `nvim_buf_set_extmark` espera. Marcas se sobrepõem.
- **Mapa** tem um campo além do pedido: `{ preview_start, preview_end, src_start, src_end }`.
  O `preview_end` (exclusivo) evita que a fase 3 deduza o fim do bloco pela entrada seguinte, e
  deixa explícito que a linha em branco entre blocos não pertence a nenhum. Só blocos de topo.
- **`code`, `table` e `html`** saem como texto cru em `render/code.lua`, `render/table.lua` e
  `render/html.lua`. As fases 4 e 5 trocam a implementação, não o nome nem a assinatura.
- **Degradação:** o dispatcher captura o erro de um módulo de tipo e desenha, no lugar daquele
  bloco, uma linha `[deckle: could not render <kind> block]` (`DeckleError`). O resto do
  documento renderiza. Tem teste que força o erro.
- **`charset = "auto"`** vira `"unicode"`, salvo `TERM=linux` ou `dumb`, que viram `"ascii"`.
  É heurística, não foi medida em terminal nenhum.
- **H1 e H2** ganham um sublinhado (`═`, `─`) do tamanho da linha mais larga: com todos os
  `DeckleH1` a `DeckleH6` linkados a `Title`, os níveis ficariam indistinguíveis.
- **Imagem** vira `[image: alt]`; link mostra só o texto (o destino não aparece).
- **Lista** sai sempre apertada: o IR não distingue lista solta de apertada. Marcador por nível
  (`•`, `◦`, `▪`; `-`, `*`, `+` em ASCII), número alinhado à direita, tarefa troca o marcador.
- **`TextChangedI` ficou de fora.** O preview renderiza em `TextChanged` e `InsertLeave`, os
  dois que o roadmap pede: digitando, o preview espera a saída do modo insert. Entra com uma
  linha em `attach` se alguém quiser (V8: um documento de 5000 linhas renderiza em ~26ms, mais
  ~110ms de parse), mas é decisão de produto, não de gate.
- **Janela de preview** sem `wrap`: o que passa da largura (código, diagrama) rola na
  horizontal em vez de ser partido. Com `config.width` e `split = "vsplit"`, a janela é
  redimensionada para essa largura.
- **Fechar mantém o buffer.** `:Deckle close` fecha a janela e remove os autocmds vivos, mas o
  buffer de preview fica, escondido, para a próxima abertura (a contagem de buffers não cresce
  por ciclo). O que o descarta é o fonte ou o próprio preview ser apagado. Sobra, por fonte,
  um autocmd (`BufDelete`/`BufWipeout`) que dispara esse descarte.
- **Eventos `User`** (`DeckleOpen`, `DeckleRender`, `DeckleClose`, com `{ src_buf, buf, win }`)
  e `preview.state(src_buf)` são o ponto de encaixe da fase 3: ela escuta o `DeckleRender`
  para reler o mapa, sem editar `preview.lua`.
- **Não foi validado:** o preview numa UI de terminal de verdade (os testes são headless, com
  teclas reais enviadas por RPC), a heurística de `charset = "auto"`, e a quebra de linha
  de CJK diante de pontuação (um `。` pode abrir uma linha: não há regra de kinsoku).

---

## Fase 3 — Sincronia de scroll

A parte de maior risco não validada, segundo a seção 12 da arquitetura. Vem antes de
qualquer coisa bonita porque um preview que não acompanha o cursor não serve.

**Entrega**

- `lua/deckle/sync.lua`: dois arrays ordenados vindos do mapa da fase 2, busca binária,
  flag reentrante para os dois autocmds não se dispararem em loop.
- `CursorMoved` no fonte move o preview, e o inverso.
- `sync = "off"` desliga tudo, incluindo os autocmds.

O mapa é parcial de propósito. A busca resolve para o bloco que contém a linha.

**Gate de saída**

1. Testes da busca binária isolada, sem Neovim: mapa vazio, uma entrada, linha antes da
   primeira, linha depois da última, linha dentro de um bloco de N para 1.
2. Teste de integração que move o cursor nos dois lados e prova que não há loop, contando
   quantas vezes cada autocmd disparou.
3. Documento de 5000 linhas: mover o cursor não trava perceptivelmente.
4. Editar o fonte, re-renderizar e sincronizar de novo continua correto com o mapa novo.

**Risco:** o loop reentrante e a invalidação do mapa após re-render. Os dois têm teste no
gate porque nenhum dos dois aparece em teste manual rápido.

**Entregue.** A API (`locate`, `src_to_preview`, `preview_to_src`, `attach`, `detach`,
`is_attached`) e as regras de resolução de linha estão no topo de `lua/deckle/sync.lua`, que é a
referência. O que difere do esboço acima ou vai além:

- **Um array, não dois.** O mapa da fase 2 já é ordenado nos dois lados, então a busca binária
  corre sobre as próprias entradas, olhando `src_start` ou `preview_start`. Não há cópia nem
  índice à parte para invalidar.
- **Resolução de linha** (a busca "para o bloco que contém a linha" ficou mais precisa):
  dentro de um bloco, interpolação linear pelo deslocamento (N linhas do fonte para 1 do
  preview cai sempre nessa uma; 1 para N cai na primeira; tamanhos iguais, identidade); entre
  dois blocos, o bloco mais próximo medido até a **borda**, e **empate vale o bloco de cima**
  (uma linha em branco entre blocos é sempre empate); antes do primeiro, a primeira linha do
  primeiro; depois do último, a última linha do último; mapa vazio, `nil`. Fora de um bloco o
  destino é a borda do bloco do outro lado, sem interpolar.
- **Quem liga a sincronia.** `preview.lua` chama `sync.attach(src)` e `sync.detach(src)` junto
  dos próprios autocmds vivos (duas linhas), em vez de a fase 3 só escutar `User`. Com `sync =
  "off"` não pode existir autocmd nenhum, nem um ouvinte global que faça o bootstrap de
  `DeckleOpen`, e o `attach` não faz nada nesse caso. Por preview aberto, o augroup
  `deckle_sync_<src>` tem três autocmds: `CursorMoved` no fonte, `CursorMoved` no preview e
  `User DeckleRender`. O mapa é relido nesse evento, lendo `preview.state(src).map`.
- **Dois mecanismos contra o loop, porque as causas são duas.** Uma flag reentrante (`busy`)
  pega o evento síncrono (um autocmd de terceiro que redispara `CursorMoved` ao ver o cursor
  mexer). E uma linha esperada por lado (`expect`) pega o evento tardio: o `CursorMoved` só
  dispara na janela em que o usuário **entra**, com o cursor onde o módulo o pôs. Sem ele,
  alternar entre janelas empurraria o cursor do fonte para a linha interpolada, e num parágrafo
  de 6 linhas que vira 1 o cursor saltaria só por trocar de janela. Cada mecanismo tem um teste
  que falha sem ele (ambiente hostil que redispara o evento para a flag; troca de janela por
  tecla para o `expect`).
- **O render realinha o preview.** No primeiro render depois do `attach`, e nos seguintes
  enquanto o foco está no fonte, o preview vai para o bloco do cursor do fonte pelo mapa novo.
  É o que faz o preview abrir onde o fonte já estava, e o que corrige a deriva depois de uma
  edição. Com o foco no preview, o render não mexe na posição de leitura (a fase 2 já a
  preserva). O teste `a posição de leitura sobrevive ao render` passou a rodar com
  `sync = "off"`, porque o que ele prova é a preservação do `write`, não a sincronia.
- **Altura da janela (opcional, feito).** Além do cursor, o destino é rolado (`winrestview`)
  para a linha de chegada ficar na mesma linha de tela do cursor de origem, limitado à última
  página cheia do buffer para não deixar um vão. Com mapa identidade o `topline` dos dois
  lados coincide (teste). Com `wrap` ligado no fonte é aproximação: a altura vem em linhas de
  tela e o `topline` em linhas do buffer.
- **Só `CursorMoved`.** Não `CursorMovedI` (o preview também não re-renderiza digitando) nem
  `WinScrolled`: rolar um dos lados com a roda ou `<C-e>`, sem o cursor sair da tela, não
  sincroniza. Fica para quem pedir.
- **`sync` é lido no `attach`.** Mudar a opção com um preview aberto vale na abertura seguinte.
- **Erro na sincronia** (a flag nunca fica presa; um aviso por mensagem, `notify_once`) tem
  teste que força o erro.
- **Gate 3, orçamento.** Média por movimento menor que 5 ms, medida dentro do Neovim com
  `nvim_exec_autocmds("CursorMoved")`, sem a ida e volta do RPC. Medido numa máquina comum, um
  documento de 5000 linhas (2000 blocos) abre em ~76 ms e cada movimento custa de 5 a 8 µs,
  conforme o sentido, contra ~4 µs do laço sem o deckle: o 5 ms é folga de CI, não o custo
  real. Fora disso, a busca sozinha faz 20 mil consultas num mapa de 100 mil blocos dentro de
  um orçamento de 1 s.
- **Não foi validado:** o redraw numa UI de terminal de verdade (os testes são headless, com
  teclas reais enviadas por RPC); o comportamento com `wrap` ligado, folds e `scrolloff` alto
  no fonte; e a rolagem pelo mouse.

---

## Fase 4 — Tabelas

**Entrega**

`render/table.lua`: largura de coluna por `strdisplaywidth`, alinhamento lido do
`pipe_table_delimiter_row`, bordas em Unicode com fallback ASCII pelo `charset`.

Tabela mais larga que a janela: truncar a coluna mais larga com reticências. Sem scroll
horizontal nesta fase.

**Gate de saída**

1. Tabela com emoji e CJK fica alinhada. É o caso que quebra quase toda implementação.
2. Célula vazia, linha com número errado de células, tabela sem corpo: nada disso lança.
3. Alinhamento à esquerda, centro e direita, cada um com teste.

**Entregue.** `render/table.lua` substitui o fallback de texto cru, com o mesmo nome e a mesma
assinatura (`render(block, ctx) -> lines, marks`). O contrato e as regras de layout estão no
topo do módulo; os testes, em `tests/test_table.lua` (os três testes do fallback saíram de
`tests/test_render.lua`). O que difere do esboço acima ou vai além:

- **Layout.** Grade completa (`┌─┬┐│├┼┤└┴┘`; `+-|` em ASCII), um espaço de cada lado do conteúdo
  e uma linha de grade só depois do cabeçalho, sem separador entre linhas do corpo. Tabela
  **sem corpo** não tem a linha de grade: o cabeçalho fecha direto na borda de baixo. A tabela
  ocupa só o que precisa e nunca é esticada até `ctx.width`.
- **Alinhamento** vale para o cabeçalho também. No centro, a célula que sobra por ser ímpar
  fica à direita.
- **Linhas tortas.** O número de colunas é `#header`. Linha curta é completada com células
  vazias; linha com **mais** células perde as extras (sem coluna nem cabeçalho, como no GFM).
- **Truncamento.** A coluna mais larga é cortada com reticências até caber, o que na prática
  nivela as colunas largas num mesmo teto (achado por busca binária, não célula a célula: uma
  célula de 1 MB não custa um milhão de voltas). A sobra de divisão inexata vai para as colunas
  da esquerda. O corte é por cluster de grafemas, então CJK, emoji e sequência com ZWJ nunca
  são partidos. Um estilo que atravessa o corte (negrito) continua nas reticências.
- **Piso e transbordo.** Uma coluna não encolhe abaixo da largura das reticências (1 célula em
  unicode, 3 em ASCII). Com colunas demais para a janela, a tabela **transborda** `ctx.width`,
  como o código: o preview não quebra linha. Não há scroll horizontal próprio.
- **Marcas.** `DeckleTableBorder` em cada glifo de borda e `DeckleTableHeader` em cada célula do
  cabeçalho (com o recuo), ambos em `lua/deckle/highlight.lua`, `default = true`, linkados a
  `Comment` e `Title`. O do cabeçalho tem `priority = 4000`, abaixo do padrão do extmark, para o
  link ou o código dentro do cabeçalho não perderem a cor. Os spans inline da célula passam por
  `render/inline.lua` (largura infinita) e as marcas saem em bytes, deslocadas para depois do
  recuo do alinhamento.
- **Desvio da regra 6 do CLAUDE.md.** A largura de uma célula é `vim.api.nvim_strwidth`, não
  `vim.fn.strdisplaywidth`. `strdisplaywidth` mede na **janela atual** e, com `wrap` ligado, soma
  uma célula quando um caractere largo cai na última coluna dela. Uma célula de CJK mais larga que
  a janela de quem chamou o render saía maior do que o preview (sem `wrap`) desenha, e a linha da
  tabela ficava curta. `nvim_strwidth` é a mesma medida (emoji, `ambiwidth`, combinantes) sem a
  janela. Há teste de regressão. Os testes de tabela estreita conferem também o
  `strdisplaywidth` direto; os de tabela larga somam por cluster, pelo mesmo motivo.
- **`ambiwidth=double`.** Os caracteres de caixa medem duas células nessa configuração (comum em
  locale CJK) e as colunas não alinhariam. Se algum glifo de borda não mede uma célula, a tabela
  usa as bordas ASCII, mesmo com `charset = "unicode"`. Há teste que força o `ambiwidth`.
- **Achado no parser, não corrigido.** O treesitter-markdown não reconhece como linha uma linha
  **final** só de células vazias (`|  |  |` no fim da tabela): devolve um nó `ERROR`, e o
  `parse.lua` o trata como parágrafo cru junto com a linha anterior. O render só vê o IR que o
  parser entrega, então o caso (linha final vazia) é coberto por IR montado à mão. Uma linha
  vazia no meio da tabela funciona. Fica para quem mexer na fase 1.
- **Não foi validado:** a tabela num terminal de verdade (os testes são headless e medem com o
  Neovim, não com a fonte do terminal: emoji que o terminal desenha com largura diferente da
  tabela do Neovim desalinham do mesmo jeito que em qualquer plugin), a tabela dentro de lista
  profunda em janela estreita, e o `ambiwidth=double` num terminal real.

---

## Fase 5 — Code blocks com highlight

**Entrega**

`render/code.lua`: moldura, e highlight usando `vim.treesitter.get_string_parser` com a
query `highlights` da linguagem do info string, aplicado como extmarks no buffer de preview.

Parser da linguagem ausente é o caso comum, não o excepcional. Degrada para bloco sem cor,
com teste que força a ausência.

Aqui morre o efeito colateral de ADR-0003: o preview não tem `filetype=markdown`, então
a injeção do treesitter não acontece sozinha.

**Gate de saída**

1. Bloco `lua` sai colorido. O parser `lua` está no core, então dá para testar sem instalar nada.
2. Bloco de linguagem inexistente sai sem cor e sem erro.
3. Bloco sem info string sai sem cor.
4. Bloco de 2000 linhas não trava o render.

**Tag `v0.1.0` sai daqui.** Preview de Markdown completo, zero dependência, camada 0.

**Entregue.** O contrato de `render/code.lua` (largura, highlight, API para quem o chama) está
em LuaCATS no topo do módulo. O nome e a assinatura `render(block, ctx) -> lines, marks` não
mudaram. O que difere do esboço acima ou vai além:

- **Moldura** em caixa fechada, com cantos arredondados (`╭╮╰╯`, `│`, `─`; `+`, `|`, `-` em
  ASCII) e o info string como rótulo na borda de cima (`╭─ lua ─────╮`). Sem info string, sem
  rótulo. Corpo com um espaço de folga de cada lado e o fundo `DeckleCode`.
- **Largura.** Código não quebra. A caixa tem `ctx.width` células e cresce até o código mais
  largo caber (já com tab expandido): todas as linhas têm a mesma largura, e a borda direita
  fica no fim do código em vez de cortar no meio dele. A janela de preview rola na horizontal
  (fase 2). O rótulo nunca alarga a caixa: se não couber, é truncado com reticências. Com
  `ambiwidth=double` a caixa fecha certo (testado).
- **Tab** vira espaços até o próximo múltiplo de 4 (`code.TABSTOP`), em células, antes de
  medir e de marcar. O parser recebe o texto original, não o expandido, porque `Makefile` e
  afins dependem do tab: as colunas das capturas são deslocadas depois.
- **Highlight** por `vim.treesitter.get_string_parser` + a query `highlights` da linguagem. Cada
  captura vira uma marca `@captura.lang` (`@keyword.lua`), o grupo que o Neovim e os esquemas
  de cores já definem, com a queda para `@keyword` quando o esquema não define o da linguagem.
  Prioridade 100 (a do highlighter do Neovim, ou o `priority` da query), com o fundo do
  bloco em 50 para uma captura com `bg` vencer. Captura de várias linhas vira uma marca por
  linha. `_privada`, `@spell`, `@nospell` e `@none` não geram marca.
- **Resolução da linguagem** (`code.resolve_lang`, só nomes `[%w_]+` chegam ao
  `language.add`, porque ele procura `parser/<nome>.*` no runtimepath e o info string vem de um
  documento que ninguém conferiu): `language.get_lang` (o que o usuário registrou com
  `register`), a tabela `code.ALIASES` (`sh`, `js`, `py`, `ts`, `yml`, `c++`...), a extensão como
  filetype (`kts` -> `kotlin`) e o nome como veio. `get_lang` sozinho **não** resolve alias:
  `get_lang("js")` devolve `"js"`, medido no 0.11.5.
- **Sem injeção.** Só a linguagem do bloco: `parser:parse()` sem argumento não roda as
  injeções, e `parse(true)` rodaria (HTML com `<script>`, comentário de doc, `vim.cmd` em Lua
  ficam só na cor da linguagem de fora).
- **`markdown` e `markdown_inline` não são coloridos.** O scanner do parser de Markdown aborta
  o Neovim com aninhamento fundo (V6), e `get_string_parser(src, "markdown")` é exatamente a
  chamada que dispararia isso. A guarda mora em `parse.lua` e conta as linhas dentro da cerca
  também, então um documento vindo de `parse.lua` com um bloco assim nem chega a este módulo;
  mas `code.render` aceita bloco sintético, e a segurança não pode depender de quem chama.
  Dá para ligar de volta exportando a guarda de `parse.lua`.
- **Tetos.** Acima de `MAX_HIGHLIGHT_LINES` (5000) ou `MAX_HIGHLIGHT_BYTES` (512 KB) o bloco
  sai sem cor e com moldura. O treesitter de string não tem timeout, e o preview re-renderiza
  a cada edição.
- **Cache** do resultado do parse por `parser .. "\0" .. fonte`, em duas gerações (um acerto
  na antiga promove a entrada), com teto de 256 entradas e 300 mil capturas por geração.
  Falha não entra no cache: instalar o parser no meio da sessão tem que fazer efeito. Os
  contadores `code.stats.parses` e `code.stats.hits` são o que os testes leem.
- **Degradação** (ADR-0004): parser ausente, `language.add` que devolve `nil, err`, `false` ou
  lança, query ausente ou que lança, parser sem árvore, parse que lança, `root()` que lança,
  nome de linguagem inválido: o bloco sai com moldura e sem cor, sem erro, sem `vim.notify`
  e sem derrubar o resto do documento. O motivo fica em `code.last_error`. Cada caso tem teste
  que o força: o parser de `lua` é escondido por stub (só ele; o Markdown precisa dos seus).
- **Nota (`block.note`)** é uma linha discreta (`DeckleCodeNote`) logo abaixo da moldura,
  truncada em `ctx.width`. É para a fase 7: o IR do parser não tem `note`, só quem chama
  `code.render` com um bloco sintético a preenche. Bloco sem linhas não produz nada, nem a
  nota.
- **Grupos novos** em `highlight.lua`: `DeckleCodeBorder` (`Comment`), `DeckleCodeLang`
  (`Type`) e `DeckleCodeNote` (`Comment`). `DeckleCode` continua o fundo do corpo.
- **Custo** (Neovim 0.11.0, 0.11.5 e nightly): ver V10 em `docs/validation.md`. Um bloco de 2000
  linhas de Lua renderiza em ~120 ms a frio e ~10 ms com cache.
- **Testes.** `tests/test_code.lua` (moldura, nota, highlight, linguagem, degradação, tamanho,
  cache, e dois casos com o preview de verdade num Neovim filho, um deles lendo o atributo
  da célula na tela). Os dois testes de fallback de `code` em `tests/test_render.lua` saíram
  (o comportamento cru não existe mais) e o de lista com código passou a esperar a moldura.
- **Não foi validado:** só os parsers `lua`, `c` e `vim` (os do core) foram exercitados. Outro
  parser pode ter o mesmo tipo de `assert` no scanner que o de Markdown tem; os tetos de
  tamanho limitam o custo, não o aborto. Nada foi visto numa UI de terminal de verdade (o
  atributo da célula na tela é lido no Neovim filho), nem o efeito de `ambiwidth=double` num
  terminal real, só o que `strdisplaywidth` mede.

---

## Fase 6 — Crate `deckle-native`

Rust isolado. Nenhuma linha de Lua muda nesta fase, e o crate se testa sozinho com
`cargo test`.

**Entrega**

- `crates/deckle-native/` com `crate-type = ["cdylib"]`, mlua 0.11 com features `module`
  e `luajit`, merman-core e merman-ascii pinados em versão exata e idêntica.
- `rust-toolchain.toml` em 1.95.
- Build que falha alto se o merman resolver para versão diferente da pinada, checado por
  `cargo tree` na CI. O modo de falha silencioso de V5 custou tempo uma vez e não deve custar de novo.
- `render(src, opts) -> Vec<String>` conforme a seção 5 da arquitetura.
- Guarda de tamanho: acima de `max_src_lines`, devolve `Err` com mensagem em vez de gastar
  46ms ou mais.
- Regra: sempre `Err`, nunca `panic!` deliberado.
- `make native` copia `libdeckle_native.so` para `deckle_native.so`. Sem isso o `require`
  não acha, conforme a pegadinha de V3.

**Gate de saída**

1. `cargo test` cobrindo os 14 tipos de `ascii_supported_diagram_types()`, cada um com
   um diagrama mínimo. A arquitetura admite que só 4 foram auditados.
2. Entrada malformada, entrada vazia e tipo não suportado devolvem `Err` com mensagem legível.
3. Um teste em Lua headless que chama o módulo dentro do Neovim, força um erro e prova que
   o processo sobrevive com exit code 0. É a reprodução de V2.2, virando teste de regressão.
4. Benchmark do flowchart grande registrado no PR, para comparar quando o merman subir de versão.

**Anti-escopo:** integração com o render de Markdown.

**Risco:** merman em alpha quebrando API. Reconferir a última alpha antes de abrir o PR e
registrar a versão escolhida no ADR-0002.

---

## Fase 7 — Mermaid no preview

**Entrega**

- `lua/deckle/native.lua`: carrega o `.so` com `pcall`, guarda o motivo da falha para o
  checkhealth, e nunca tenta de novo na mesma sessão.
- `render/mermaid.lua`: bloco com info string `mermaid` chama o nativo, e qualquer erro
  degrada aquele bloco para code block cru com uma nota discreta.
- Cache por hash do conteúdo do bloco mais largura mais charset. Diagrama grande custa 46ms
  e não pode ser recalculado a cada `CursorMoved`.
- `checkhealth` passa a reportar camada 1 e a listar os tipos suportados em runtime.

**Gate de saída**

1. Com o `.so` presente, um `sequenceDiagram` renderiza no preview.
2. Com o `.so` removido, o mesmo arquivo abre e o bloco vira código cru. Teste automatizado,
   não verificação manual.
3. Diagrama sintaticamente inválido degrada só aquele bloco. O resto do documento renderiza.
4. Reabrir o mesmo documento acerta o cache, verificado por contador.
5. `charset = "ascii"` produz saída sem Unicode.

**Entregue.** `lua/deckle/native.lua` (carregador), `lua/deckle/render/mermaid.lua` (módulo do
bloco, cache e degradação) e a camada 1 no `lua/deckle/health.lua`. O contrato de cada um está
no comentário do topo do arquivo; é a referência da fase 9 e do resto. O que difere do plano
acima ou vai além dele:

- **Despacho.** O dispatcher manda para `render/mermaid.lua` todo bloco `code` cujo `lang` é
  exatamente `mermaid` (minúsculo; `Mermaid` e `mermaidx` seguem como código). É o único diff em
  `render/init.lua`.
- **`deckle.native`: `get()`, `status()`, `reset()`.** `get()` devolve o módulo de Rust ou `nil`.
  A ordem de carga é `native.path` (por `package.loadlib`), `require("deckle_native")` (o
  `lua/deckle_native.so` do `make native`, no runtimepath) e, por fim, o que
  `install.info().path` aponta (por `package.loadlib`). **`native.path` é caminho explícito e
  manda**: configurado e sem carregar, não cai para os degraus seguintes, porque carregar outro
  binário em silêncio esconderia o erro de configuração (o motivo vai ao checkhealth). O resultado
  da carga, bom ou ruim, é guardado pela sessão: nunca tenta de novo. `native.enabled` é lido a
  cada chamada, não guardado, então desligar vale na hora e religar carrega. `status()` só lê
  (`enabled`, `attempted`, `loaded`, `source`, `path`, `version`, `reason`) e não provoca a
  carga; o checkhealth chama `get()` antes. `reset()` é só para teste.
- **Degradação.** Qualquer falha (sem módulo, `native.enabled = false`, parse, grande demais, tipo
  fora dos 14, resposta inválida, erro do próprio módulo) vira, só para aquele bloco, o
  `render/code.lua` com `{ lang = "mermaid", lines, note }`: moldura com rótulo `mermaid` e a nota
  `mermaid: <motivo>` numa linha `DeckleCodeNote` sob ela, cortada na largura pelo `code.lua`. O
  motivo completo, sem corte, fica em `render.mermaid.last_error`. **Um `mermaid` sem nenhuma
  linha não desenha nada** (nem nota), que é o que o `code.lua` faz com qualquer cerca vazia.
- **Linha mais larga que a janela fica inteira.** O `width` do `ctx` vai ao crate como meta (o
  merman tenta o perfil compacto), e o que ainda sobrar transborda como código: a janela de
  preview não tem `wrap` e rola na horizontal. Cortar desalinharia a caixa, e o reflow é do
  merman. Medido com um flowchart `LR` de quatro nós: 105 células numa janela de 40, sem
  reticências, e o merman quebra o rótulo dentro do nó em vez de alargá-lo.
- **Cache.** Chave é o SHA-256 (o `deckle.sha256`, que aceita NUL) de conteúdo, largura, charset,
  **`max_src_lines` e `diagram_ty`**: os dois últimos mudam o resultado, e sem eles um erro de
  "grande demais" seria servido depois de o limite subir. LRU de `cache_limit` (64) entradas, por
  varredura do mais antigo, que só corre ao estourar o limite. Guarda também o **erro** do
  render, que é determinístico e custa o mesmo que um sucesso; **não** guarda "nativo
  indisponível", que é estado da sessão e não do diagrama. `cache_stats()` devolve
  `{ hits, misses, size, limit }`: `hits` são consultas respondidas pelo cache, `misses` as que
  foram ao crate; bloco sem nativo disponível ou com mais linhas que `max_src_lines` (o crate o
  recusa antes do layout, de graça) não passa pelo cache e não conta em nenhum. Quem recebe as
  linhas recebe uma cópia. Medido num flowchart de 60 arestas (605 linhas): 51,6 ms no primeiro
  render, que inclui o `dlopen`, e 0,23 ms nos seguintes.
- **`diagram_ty` só vem do bloco.** O módulo repassa `block.diagram_ty` se for string, mas nada no
  parser o preenche (a cerca só diz `mermaid`): ele existe para quem montar um bloco à mão.
- **Checkhealth.** Camada 1 quando o módulo carregou, com a versão, de onde veio e os tipos de
  `supported_types()` lidos em runtime. Sem módulo é camada 0 com o motivo: `info` quando não há
  binário nenhum ou `native.enabled = false` (é o estado normal, nada a consertar), e `warn`
  com o que fazer quando há um binário (`native.path` ou o instalado) que não carregou. É o
  único ponto do checkhealth que carrega o `.so`; a seção "Native binary" continua só lendo o
  disco.
- **Testes que exigem o `.so`.** `tests/native/test_mermaid_native.lua` (mini.test) é o gate com o
  merman de verdade. Sem `lua/deckle_native.so` os casos são **pulados com aviso** (o job `test`
  não tem Rust e roda a suíte inteira); `scripts/test-native.sh` o roda depois do `make native`
  com `DECKLE_REQUIRE_NATIVE=1`, e aí a falta do `.so` falha. A degradação, o cache e o
  carregador têm teste que não precisa do `.so` (`tests/test_mermaid.lua`, `tests/test_native.lua`,
  um crate falso em `package.loaded`), e esses rodam em todo job. `tests/test_config.lua`
  descarta `deckle.config` do `package.loaded`: teste que guarda o módulo no topo do arquivo
  enxerga uma instância velha, e por isso `test_mermaid.lua` o pega por `require` a cada uso.
- **Não foi validado:** o preview numa UI de terminal de verdade (como na fase 2); a cor de
  `DeckleMermaid` (`Special`) em nenhum esquema; os oito tipos que saem como texto estruturado
  (`gantt`, `mindmap`, `timeline`...) passando pelo preview, que só foram exercitados no crate; e
  um diagrama de 200 linhas (o limite) no re-render de um documento de 5000 linhas.

---

## Fase 8 — Distribuição

**Entrega**

Seguindo o caminho do blink.cmp, citado na seção 9 da arquitetura.

- Matriz de release: linux, macos e windows por x86_64 e aarch64.
- `lua/deckle/install.lua`: baixa o binário da release, confere SHA-256, cai para
  `cargo build --release` se não houver binário da plataforma, e cai para camada 0 se as
  duas falharem.
- macOS precisa das flags de link que a seção 12 admite nunca terem sido exercitadas.
  Se a fase 8 travar, trava aqui.
- `checkhealth` diz de onde veio o binário: release, build local ou ausente.

**Gate de saída**

1. Release de teste em tag `v0.2.0-rc` produz artefato para cada alvo da matriz.
2. Checksum errado aborta a instalação e cai para camada 0, testado com um checksum falso.
3. Instalação sem rede termina em camada 0 sem erro visível ao usuário além do checkhealth.

**Tag `v0.2.0` sai daqui.**

**Entregue.** Workflow em `.github/workflows/release.yml`, instalador em `lua/deckle/install.lua`.
O contrato com a fase 7 e a decisão de onde o binário mora estão na seção 9 da arquitetura.
O que difere do plano acima ou vai além dele:

- **O gate 1 foi provado numa rodada de PR, não numa tag.** `gh workflow run release.yml
  --ref feat/f8-distribuicao` responde `HTTP 404: workflow release.yml not found on the default
  branch`: um `workflow_dispatch` de arquivo novo só existe depois de entrar na `main`. O
  workflow ganhou um gatilho `pull_request` (só em paths que entram no binário), e a matriz
  rodou por ele. A prova via tag `v0.2.0-rc` fica para depois do merge, e é a única que exercita
  o job `release` (publicação, conferência de 12 arquivos e dos `.sha256`). Nenhuma tag nem
  release foi criada nesta fase.
- **Smoke test do artefato antes de publicar.** Em cada runner nativo, o instalador de verdade
  instala o artefato de um diretório local (`file://`), `package.loadlib` o carrega pelo caminho
  de `info()` e roda a bateria de `tests/native/native_headless.lua` (inclusive "erro em Rust não
  derruba o Neovim"). É o que prova que o `.dylib` do macOS e a `.dll` do Windows carregam num
  Neovim, e não só que compilam.
- **Runners.** `macos-13` e `macos-14` não existem mais ("The configuration
  'macos-14-arm64-us-default' is not supported"). A matriz usa `macos-15-intel` (x86_64) e
  `macos-15` (arm64). O aarch64 do Windows é cross-compilado no `windows-latest` x64: o mlua usa
  `raw-dylib` no Windows, então não precisa de import lib, mas um runner x64 não executa aarch64,
  e esse alvo sai **sem smoke test**.
- **`vim.fn.sha256` não serve para binário** (`E976: Using a Blob as a String` com byte NUL),
  então o hash é `lua/deckle/sha256.lua`, em Lua puro: 0,15 s para o `.so` de 10,5 MB, igual ao
  `sha256sum`, e provado contra os vetores do NIST e contra o `sha256sum` nas bordas de bloco.
- **Checksum errado não cai para o cargo.** O gate diz "aborta a instalação e cai para a camada
  0", e foi lido literalmente: um binário que não bate com o hash é evento de integridade, não
  "sem binário para a plataforma". Falha de download (404, sem rede, sem curl) é que cai para
  o cargo.
- **`Cargo.lock` versionado**, e todo build de release usa `--locked`. Era a causa-raiz de V5
  (cargo resolvendo merman para outra versão sem avisar).
- **Instalação em `stdpath("data")/deckle/`**, com `install.json` (origem, versão, alvo, SHA-256).
  Troca por `rename`, nunca escrevendo por cima de um `.so` que um Neovim pode ter mapeado.
  Binário de versão diferente da do plugin conta como ausente.
- **Fora da matriz:** Linux com musl (Alpine) é detectado e vai direto para o cargo, porque o
  `.so` de glibc não carrega lá.
- **`version.lua` diz `0.2.0` antes de a release `v0.2.0` existir.** Até a tag sair, o download
  dá 404 e o instalador cai para o cargo, que é o comportamento desenhado.

---

## Fase 9 — Camada 2: imagens

**Entrega**

- `lua/deckle/caps.lua`: detecção de kitty, iTerm2 e sixel, com o cuidado que ADR-0004 pede
  para tmux e SSH. Na dúvida, camada mais baixa.
- Imagem do Markdown vira imagem de verdade onde o protocolo existe, e alt text onde não existe.
- Reposicionar a imagem no scroll, que é a parte difícil e a razão de esta fase vir por último.

**Gate de saída**

1. Detecção com `TERM` e variáveis de multiplexer forjadas cobre kitty, tmux mentindo,
   SSH e terminal burro.
2. Sem protocolo gráfico, a imagem vira alt text e nada mais muda.
3. Fechar o preview limpa as imagens da tela.

**Risco:** é a fase com maior chance de ser cortada. Se custar mais do que vale, a camada 2
fica para depois da v1.0 e o plugin continua íntegro. Camada 0 e 1 não dependem dela.

**Entregue.** A fase foi cortada ao que dá para entregar íntegro e testado: detecção completa,
**imagem só pelo protocolo do kitty**. O contrato de `lua/deckle/caps.lua` (detecção), de
`lua/deckle/image/` (protocolo, PNG, estado) e de `lua/deckle/render/image.lua` (gancho do render)
está em LuaCATS no topo de cada um; os testes são `tests/test_caps.lua`, `tests/test_image.lua` e
`tests/test_preview_images.lua`. O que difere do esboço acima ou vai além:

- **`caps.detect(env, opts)` é pura**, de uma tabela de ambiente, e devolve `{ layer, graphics,
  reason, terminal, multiplexer, remote }`. `layer` é o que o *terminal* deixa subir (0 burro:
  `TERM` ausente, `dumb` ou `linux`; 1 texto; 2 há protocolo gráfico), não a camada do plugin.
  `graphics` é o protocolo que o terminal fala: `"kitty"` (kitty e ghostty), `"iterm2"` (iTerm2 e
  WezTerm) e `"sixel"` (foot, mlterm, contour). `caps.current()` é a cola com o ambiente real,
  memoizada, e `caps.set_override` é o gancho dos testes. Na dúvida, sem gráfico: tmux só com
  `allow-passthrough` **confirmado** (consulta ao `tmux show-options`) e o terminal de fora
  reconhecido por variável que não seja `TERM`/`TERM_PROGRAM` (que no tmux mentem); SSH, GNU screen
  e terminal burro, nada. `images.enabled = true` levanta as barras do tmux e do SSH, e **só** elas:
  não inventa um protocolo para terminal não reconhecido, nem salva um `TERM=dumb`.
- **Config nova** `images = { enabled = "auto" | true | false, max_height = 20 }`, validada.
- **Abordagem: Unicode placeholders** (`U+10EEEE` com diacríticos de linha e coluna, id da imagem
  na cor do primeiro plano), e não o posicionamento por coordenada. O placeholder é texto: o
  Neovim o rola e o redesenha com o buffer, então a parte difícil do roadmap (reposicionar no
  scroll) **não existe**. A sincronia de scroll da fase 3 não mudou: o bloco da imagem é um bloco
  do mapa com N linhas. O custo é outro: o id cabe em um byte (ids de 16 a 255, 240 imagens por
  vez; de 16 em diante o Neovim escreve o id como `38;5;<id>`, a forma da documentação do kitty),
  cada imagem ganha um grupo `DeckleImg<id>` com o id na cor, e um `CursorLine` com `fg` pode
  estragá-lo. O tamanho da célula em pixels não está na API do Neovim: o deckle supõe 10 x 20 para
  decidir quantas linhas reservar, e o kitty encaixa a imagem no retângulo mantendo a proporção.
- **O que vira imagem:** só o parágrafo que é **uma imagem sozinha**, PNG **local** (caminho
  relativo ao fonte, absoluto ou `~/`; `%20` decodificado). URL, `data:`, JPEG, SVG, arquivo
  ausente, grande demais ou com cabeçalho que não é de PNG viram `[image: alt]`, sem erro. Imagem no
  meio de texto, dentro de link (selo), em item de lista ou ao lado de outra imagem continua texto
  alternativo. As dimensões saem do `IHDR`, sem decodificar nada.
- **Transmissão:** por caminho (`t=f`) quando o terminal lê o disco desta máquina; pelos bytes,
  em pedaços de 4096 de base64 (`t=d`), numa sessão remota com opt-in (teto de 4 MiB). `q=2` em
  todo escape: nenhuma resposta do terminal cai na entrada do Neovim. Dentro do tmux, cada escape
  sai em `DCS tmux;`.
- **Toda escrita no terminal passa por uma função** (`image.set_writer`). O padrão escreve em
  `vim.v.stderr` (que, com TUI, é o tty; o stdout é o RPC) e **só** com uma UI de terminal
  (`stdout_tty`) ligada: nos testes, em headless, nada vai ao terminal real.
- **Ciclo de vida:** o id de uma imagem é estável entre renders enquanto arquivo e tamanho não
  mudam, então editar o texto não retransmite nada. Fechar o preview (`:Deckle close`, `:close` na
  janela, apagar o fonte) manda `a=d,d=I,i=<id>` por imagem (só as do deckle, nunca `d=a`), que
  também libera a memória do terminal; `VimLeavePre` apaga o que sobrou. `:Deckle refresh`
  retransmite (o terminal pode ter perdido as imagens).
- **`:checkhealth`** ganhou a seção "Terminal graphics": a camada, o protocolo e o motivo.
- **Fora desta fase:** **iTerm2 e sixel** são detectados e renderizam texto alternativo (a saída
  de `health` diz "not supported yet"); mais de uma imagem por parágrafo; imagem remota e outros
  formatos; leitura do tamanho real da célula; `WinScrolled` (não é preciso); camada 3 (`mmdc`).
- **Não foi validado em terminal real:** o desenho no kitty, no ghostty (que implementa o
  protocolo, Unicode placeholders inclusive, mas não foi aberto) e no tmux com passthrough. O que
  foi verificado é o que sai do Neovim: num Neovim com TUI dentro de um pty, o `:Deckle open`
  escreve no tty os escapes de transmitir e posicionar, o Neovim emite as células com o id em
  `38;5;16m` (256 cores) e `38:2:0:0:16m` (`termguicolors`) e o `:Deckle close` escreve o delete.
  O que um kitty de verdade faz com isso, a proporção com a célula real, `CursorLine` com `fg`,
  rolagem horizontal da janela e o redraw parcial do Neovim sobre células de placeholder ficam
  sem medida.

---

## Fase 10 — Documentação e polimento

**Entrega**

- `doc/deckle.txt` com tags, escrito à mão, não gerado.
- README com instalação por lazy.nvim e packer, e a tabela de camadas.
- Exemplos em `examples/` com um `.md` que exercita todo tipo de bloco, útil como teste manual.
- ADR novo registrando o piso de versão do Neovim, que hoje é suposição.

**Tag `v0.3.0` sai daqui.**

**Entregue.** `doc/deckle.txt`, o README reescrito, `examples/showcase.md` (mais
`examples/assets/folha.png`), o [ADR-0005](adr/0005-piso-neovim-0-11.md) e a suíte que prende
tudo isso ao código: `tests/test_doc.lua`, `tests/test_showcase.lua`,
`tests/native/test_docs_native.lua` e `tests/doc_helpers.lua`. A tag `v0.3.0` **não** foi criada
neste PR. O que difere do esboço acima ou vai além:

- **`doc/deckle.txt`** é vimdoc em português, escrito à mão (um formatador de uma vez só alinhou
  os cabeçalhos à coluna 78; o arquivo não é gerado de nada), com linhas de até 78 colunas e a
  modeline no fim. Tags: `deckle`, uma por seção (`deckle-install`, `deckle-commands`,
  `deckle-config`, `deckle-layers`, `deckle-mermaid`, `deckle-images`, `deckle-sync`,
  `deckle-highlights`, `deckle-api`, `deckle-health`, `deckle-limitations`), uma por opção
  (`deckle-config-<caminho>`), uma por subcomando (`:Deckle-<nome>`), uma por grupo de highlight
  (`hl-Deckle...`) e uma por evento `User`. As limitações vêm dos "Entregue" das fases 1 a 9.
- **A documentação é conferida por teste, e cada caso liga o texto a uma fonte de verdade.**
  `:helptags` roda num diretório temporário (o checkout não ganha `doc/tags`), sem erro, e um
  Neovim filho abre `:help deckle` e as tags de formato difícil; toda `|tag|` existe, no doc ou
  em `$VIMRUNTIME/doc/tags`; nenhuma linha passa de 78 colunas; toda chave de
  `config.known_keys()` tem tag `deckle-config-<caminho>`; **o bloco de valores de fábrica do
  doc e o do README, executados, são iguais a `config.defaults()`**; todo subcomando de
  `init.lua`, todo evento que `preview.lua` emite e todo alvo de `install.release_targets()`
  aparecem; todo grupo de `highlight.groups` tem tag com o padrão certo (`DeckleH1 (link:
  Title)`); o piso de versão de `plugin/deckle.lua` é o de `health.lua`, do doc, do README e do
  ADR; todo link relativo dos Markdown do projeto aponta para um arquivo que existe. Oito
  mutações (tag de grupo removida, default alterado, `|tag|` inexistente, grupo novo sem doc, opção
  nova sem doc, captura do README alterada, link quebrado, showcase sem o `pie`) fazem a suíte
  falhar, e foram conferidas à mão.
- **`config.known_keys()`** é a única mudança de código da fase: devolve as chaves aceitas em
  cada nível, inclusive as de padrão `nil` (`width`, `native.path`) que `defaults()` não tem. Sem
  ela o teste não enxergaria uma opção nova de padrão `nil`.
- **O README tem a captura do render e o fonte dela, e a captura é a saída real.** O caso de
  `tests/native/test_docs_native.lua` renderiza o fonte (60 colunas, Unicode, com o `.so`) e
  compara com a captura, linha a linha sem o espaço do fim. Se o merman mudar a arte, ele falha. O
  `scripts/test-native.sh` o roda, então o job `native` da CI o exige; no job `test`, sem Rust, é
  pulado com aviso.
- **`examples/showcase.md`** tem todo tipo de bloco (títulos ATX e setext, ênfases, listas
  aninhadas até o quarto nível e de tarefa, citações em três níveis, tabelas com os três
  alinhamentos, CJK e emoji, truncamento e linha curta, código `lua`, `c`, sem linguagem e de
  linguagem inexistente, três diagramas `mermaid` (sequência, fluxograma e um `pie`, que degrada de
  propósito), imagens, regra e HTML). `tests/test_showcase.lua` o renderiza em quatro larguras e
  nos dois charsets sem `DeckleError`, abre o preview de verdade, confere que o IR tem todos os
  tipos, e, com protocolo gráfico forjado, que a imagem sozinha vira 20 x 5 placeholders e que o
  `:Deckle close` a apaga; sem protocolo, texto alternativo e nenhum byte no terminal. O PNG é
  200 x 100, 2,6 KB, gerado à parte (RGB, sem dependência).
- **Dois testes dependiam do terminal de quem os roda** e passaram a fixar `TERM` no filho
  (`test_sync.lua`, o empate entre blocos, e `test_code.lua`, a cor na tela): com `TERM=dumb` ou
  `linux` o `charset = "auto"` vira ASCII, e os dois procuravam um glifo Unicode. A suíte inteira
  passa com `TERM=xterm-256color`, `dumb` e `linux`. O teste do README em `test_preview.lua`, que
  exigia que o preview não tivesse `**` nem `# deckle.nvim`, passou a olhar só o texto antes da
  primeira moldura de código, porque o README agora mostra Markdown de exemplo numa cerca.
- **Comentário de `render/table.lua` e `docs/architecture.md`** diziam que a tabela mede com
  `strdisplaywidth`, e ela usa `nvim_strwidth` (fase 4). A regra 6 do `CLAUDE.md` ganhou a
  ressalva. O `CLAUDE.md` e o README descreviam as fases 0, 1, 2, 3, 6 e 8, com tabela, código e
  HTML "como texto cru".
- **packer:** a instalação por `run = ":Deckle install"` segue o que o lazy.nvim faz com
  `build = ":Deckle install"` (que o código do lazy confirma: carrega o plugin antes do comando) e
  o uso de `run = ":TSUpdate"` no nvim-treesitter, mas **não foi testada com o packer**.
- **Não foi validado:** o `:help` com a cor do esquema do usuário (só as tags e o carregamento);
  a instalação por packer; e nada do plugin numa UI de terminal de verdade (como nas fases
  anteriores).

---

## Dependências entre fases

```
0 ──► 1 ──► 2 ──► 3 ──► 4 ──► 5 ──► v0.1.0
                  │
                  └──► 6 ──► 7 ──► 8 ──► v0.2.0
                                   │
                                   └──► 9 ──► 10 ──► v0.3.0
```

A fase 6 é Rust puro e não depende de 4 nem de 5. Dá para adiantar em paralelo se a
vontade de mexer no merman falar mais alto que a disciplina do roadmap.

## Fora de escopo do projeto inteiro

Registrado aqui para não voltar como ideia a cada duas semanas:

- Editar vendo o render ao lado no mesmo texto. É markview.nvim, e ADR-0003 já explicou.
- Exportar para HTML ou PDF.
- LaTeX e KaTeX.
- Servidor web, webview, browser.
- Suporte a Vim.

## Decisões ainda em aberto

- **Piso de Neovim.** ~~Proposto~~ **medido na CI da fase 0**: o Neovim 0.10.4 reprova 20
  dos 39 casos. A causa não é bug — é `vim.validate` com a assinatura nova, que só existe a
  partir do 0.11, mais a guarda do `plugin/deckle.lua`, que se recusa a registrar `:Deckle`
  abaixo do piso e faz todo teste de despacho bater em `E492`. O job saiu da matriz em vez
  de ficar permanentemente vermelho. Fica em **0.11.0**; virou o
  [ADR-0005](adr/0005-piso-neovim-0-11.md) na fase 10.
- **macOS e Windows.** ~~Nada foi testado. A fase 8 é a primeira que descobre.~~ **Medido na
  fase 8**: o módulo compila, instala pelo instalador e carrega num Neovim 0.11.0 de verdade em
  Linux x86_64 e aarch64, macOS x86_64 e arm64 e Windows x86_64, com as flags de
  `.cargo/config.toml` no macOS. Windows aarch64 só compila (cross). Ver "Entregue" na fase 8 e
  V9 em `docs/validation.md`.
- **Versão do merman.** O pin de `0.8.0-alpha.6` veio da validação de 2026-09-06. ~~Reconferir
  na fase 6.~~ **Reconferido na fase 6 (2026-11-17)**: o pin fica, mas já existem `0.8.0` e
  `0.10.0` na crates.io. Subir é um PR próprio; ver ADR-0002.
- **Sobrevivência da camada 2.** Decidir depois da v0.2.0, com uso real na mão.
