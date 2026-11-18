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

Nenhuma delas está em ADR ainda. Estão aqui para serem contestadas antes de virarem código.

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

---

## Fase 10 — Documentação e polimento

**Entrega**

- `doc/deckle.txt` com tags, escrito à mão, não gerado.
- README com instalação por lazy.nvim e packer, e a tabela de camadas.
- Exemplos em `examples/` com um `.md` que exercita todo tipo de bloco, útil como teste manual.
- ADR novo registrando o piso de versão do Neovim, que hoje é suposição.

**Tag `v0.3.0` sai daqui.**

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
  de ficar permanentemente vermelho. Fica em **0.11.0**; vira ADR na fase 10.
- **macOS e Windows.** ~~Nada foi testado. A fase 8 é a primeira que descobre.~~ **Medido na
  fase 8**: o módulo compila, instala pelo instalador e carrega num Neovim 0.11.0 de verdade em
  Linux x86_64 e aarch64, macOS x86_64 e arm64 e Windows x86_64, com as flags de
  `.cargo/config.toml` no macOS. Windows aarch64 só compila (cross). Ver "Entregue" na fase 8 e
  V9 em `docs/validation.md`.
- **Versão do merman.** O pin de `0.8.0-alpha.6` veio da validação de 2026-09-06. ~~Reconferir
  na fase 6.~~ **Reconferido na fase 6 (2026-11-17)**: o pin fica, mas já existem `0.8.0` e
  `0.10.0` na crates.io. Subir é um PR próprio; ver ADR-0002.
- **Sobrevivência da camada 2.** Decidir depois da v0.2.0, com uso real na mão.
