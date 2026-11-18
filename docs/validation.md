# Validação empírica

Tudo aqui foi medido, não deduzido. Ambiente: Neovim 0.11.5, Fedora 42 (Linux 6.19),
rustc 1.93 (e 1.98 via rustup para o merman atual), LuaJIT 2.1.

---

## V1 — Os parsers de Markdown vêm do core do Neovim

**Por quê importa:** define se o plugin precisa do nvim-treesitter como dependência.

```sh
nvim --headless -u NONE -l /dev/stdin <<'EOF'
for _, lang in ipairs({'markdown','markdown_inline'}) do
  print(lang, vim.api.nvim_get_runtime_file('parser/'..lang..'.*', true)[1])
end
EOF
```

**Resultado:**
```
markdown        /usr/lib64/nvim/parser/markdown.so
markdown_inline /usr/lib64/nvim/parser/markdown_inline.so
```

Com `-u NONE` — nenhum plugin carregado. Os parsers vêm da instalação do Neovim.
**Conclusão: zero dependência de plugin para parsing.**

Nós confirmados como existentes no parser: `atx_heading`, `paragraph`, `list`,
`list_item`, `pipe_table` (+`_header`/`_delimiter_row`/`_row`/`_cell`),
`fenced_code_block` (+`info_string`/`language`/`code_fence_content`), `block_quote`,
`section`; e no `markdown_inline`: `strong_emphasis`, `emphasis`, `code_span`,
`inline_link`, `image`, `link_text`, `link_destination`, `image_description`.

Injeção de linguagem dentro de code fence **funciona sem plugin** (testado com `lua`),
mas depende do parser daquela linguagem estar instalado — logo, highlight de code block
precisa degradar quando o parser não existe.

---

## V2 — Um panic em Rust atravessando FFI mata o Neovim

**Por quê importa:** é a diferença entre "o diagrama não renderizou" e "o usuário perdeu
o trabalho não salvo".

Com `nvim-oxi` 0.6.0 + feature `neovim-0-11`, uma função que dá `panic!`:

```
thread '<unnamed>' panicked at src/lib.rs:11:25:
layout impossivel: ciclo nao resolvido
thread '<unnamed>' panicked at library/core/src/panicking.rs:225:5:
panic in a function that cannot unwind
thread caused non-unwinding panic. aborting.
Abortado (imagem do núcleo gravada)

exit code: 134
```

`pcall` **não** captura. A fronteira `extern "C"` é non-unwinding, então o panic vira
`panic_cannot_unwind` → `abort()`.

### V2.1 — Isolando a causa

Três variantes testadas com nvim-oxi:

| variante | resultado |
|---|---|
| `panic!` solto | **abort**, exit 134 |
| `catch_unwind` interno **e retorna `Err`** | **abort**, exit 134 |
| `catch_unwind` interno **e retorna `Ok(fallback)`** | sobrevive, exit 0 |

Ou seja: `catch_unwind` funciona. Quem aborta é **retornar `Err` de uma `Function` do
nvim-oxi**. Isso corresponde à issue [noib3/nvim-oxi#231][231], aberta, onde
desserializar dados errados de Lua crasha o Neovim em vez de virar erro Lua.

[231]: https://github.com/noib3/nvim-oxi/issues/231

### V2.2 — `mlua` trata os dois casos corretamente

Mesmo teste com `mlua` 0.11 (features `module`, `luajit`):

```
[Err]   pcall pegou = true | msg = runtime error: mermaid: sintaxe invalida na linha 3
[panic] pcall pegou = true | msg = ciclo nao resolvido
render AINDA funciona depois dos dois: { "[w=1] z" }
exit code: 0
```

`Err` vira erro de Lua com mensagem limpa; `panic!` cru é convertido em erro de Lua; o
módulo continua utilizável depois. **Base do [ADR-0001](adr/0001-mlua-sobre-nvim-oxi.md).**

---

## V3 — Round-trip Lua ↔ Rust funciona

Módulo Rust compilado como `cdylib`, carregado por `require`, devolvendo tabela
estruturada, e o Lua plantando o resultado num buffer `nomodifiable` com extmarks:

```
modulo carregado: { "render" }
lines: { "[w=80] flowchart TD", "[w=80]   A --> B" }
buffer read-only ok, linhas: 2
extmarks: 1
```

**Pegadinha:** o cargo gera `libdeckle_native.so`, mas o `require` só encontra se o
arquivo se chamar `deckle_native.so` — o prefixo `lib` precisa ser removido na instalação.

**Pegadinha 2 (nvim-oxi):** `Dictionary::from_iter` infere tipo homogêneo pelo primeiro
par, então funções de assinaturas diferentes precisam ser envolvidas em `Object::from`.

---

## V4 — Binário ausente degrada de forma capturável

```lua
local ok, err = pcall(require, 'deckle_native_inexistente')
-- ok = false, err = string
```

O plugin pode carregar e funcionar sem o componente nativo. **Base da camada 0.**

---

## V5 — `merman-ascii` renderiza mermaid sem Node nem Chromium

**Por quê importa:** decide se o mermaid é um projeto de meses ou uma dependência.

`merman-ascii` 0.8.0-alpha.6 + `merman-core` 0.8.0-alpha.6, rustc 1.98.

### Tipos suportados (via `ascii_supported_diagram_types()`, em runtime)

```
(14) ["class", "er", "flowchart", "gantt", "gitgraph", "journey", "kanban",
      "mindmap", "packet", "sequence", "state", "timeline", "treeView", "xychart"]
```

### Saída real — sequenceDiagram

```
┌───────┐     ┌──────┐
│ Alice │     │ John │
└───┬───┘     └───┬──┘
    │             │
    │ Hello John  │
    ├────────────►│
    │             │
    │ Great!      │
    │◄┈┈┈┈┈┈┈┈┈┈┈┈┤
    │             │
    │ Ok bye      │
    ├────────────►│
```

### Saída real — classDiagram

```
┌──────────┐
│ Animal   │
├──────────┤
│ +int age │
└──────────┘
      △
      │
 ┌─────────┐
 │ Duck    │
 ├─────────┤
 │ +swim() │
 └─────────┘
```

### Bug encontrado — nó losango

`{Deu certo?}` num flowchart renderiza como sobreposição de caixa arredondada e `<`:

```
╭────────────╮
╭            ╮
< Deu certo? ├──┐
╰            ╯  │
╰──────┬─────╯  │
```

Reproduz nos dois charsets (Unicode e ASCII), logo é bug de layout, não de charset.
Cosmético — não impede uso.

### Charset ASCII puro funciona

Para terminais sem Unicode, `AsciiCharset::Ascii` produz `+--+`, `|`, `v`, `->`.

### Performance

| caso | parse | render |
|---|---|---|
| sequence pequeno | — | <1ms |
| flowchart médio (6 arestas, 35 linhas) | 103µs | **1.42ms** |
| flowchart grande (48 arestas, 405 linhas) | 299µs | **46.13ms** |

O parse é irrelevante; o custo está no layout, e cresce rápido. 1.4ms serve para preview
ao vivo; 46ms exige debounce e cache por hash do bloco.

### Atritos

- **MSRV 1.95.** Com rustc 1.93 o cargo silenciosamente resolve para `0.7.0-alpha.1`.
- **API quebra entre alphas.** De 0.7 para 0.8: `render_model` saiu da raiz, `p.model`
  virou `p.model()`, e `render_model` passou a exigir `OperationControl`,
  `OperationContext` e `AsciiResourcePolicy`.
- **`merman-core` e `merman-ascii` precisam de versão idêntica e pinada** — `cargo add`
  resolveu versões diferentes para os dois e não compilou.
- **0.7.0-alpha.1 não suportava `sequenceDiagram`** e corrompia caixas com arestas
  roteadas por dentro. 0.8.0-alpha.6 corrigiu os dois. Ritmo de mudança é alto.

**Base do [ADR-0002](adr/0002-merman-sobre-implementacao-propria.md).**

---

## V5b — Onde o layout de texto do merman para, e o que a 0.10.0 muda

**Por quê importa:** um bug report real (o primeiro diagrama do README do projeto ILZA, um
`flowchart TB` com subgraphs aninhados e `direction` diferentes, mais o terceiro bloco do mesmo
README, um `graph LR` com subgraphs) caía em
`unsupported diagram: ASCII rendering does not support `routes crossing reserved graph
geometry` for `flowchart` yet`. A pergunta era se subir o merman ou mudar uma opção resolvia.

`merman-ascii` e `merman-core` em `0.8.0-alpha.6` e em `0.10.0`; rustc 1.95.0, Linux x86_64,
release. Cada linha abaixo veio de um crate de laboratório fora do repositório, que lê o
diagrama de um arquivo e chama o renderer com a opção da linha. A `0.8.0` estável não foi medida.

### A causa

A mensagem vem de `graph/routing.rs` (`prepare_route_scene_with_execution`): para cada aresta o
merman monta rotas candidatas (a `0.10.0` acrescenta portas cardeais alternativas numa grade
grossa) e descarta as que cruzam geometria reservada: nós, bordas e títulos de grupo, células
de terminal de outra aresta, rótulo sem lugar livre, marcador de seta sem berço. Se nenhuma
candidata sobra, é `UnsupportedFeature`. Não é erro de sintaxe, de largura nem de opção.

Cortando só **arestas** (estrutura e nós intactos), o diagrama de arquitetura do ILZA falha com
**uma** aresta na alpha (`GUARDRAIL -->|"Validação"| OPENAI`) e com **duas** na `0.10.0`
(`ENGINE --> SESSION` e `API -->|"Start Workflow"| TEMPORAL_SRV`). Cortando linhas, sobra uma
reprodução de 25 linhas (subgraphs vazios e duas arestas para nós soltos), que virou o teste
`GROUP_EDGES` do crate. Cada uma das 26 linhas de aresta do diagrama renderiza sozinha na
`0.10.0`; na alpha, 5 reprovam sozinhas. Sozinha, a cadeia `A_PRES --> A_APP --> A_DOMAIN` do
`graph LR` reprova na `0.10.0` e passa na alpha.

### O que foi tentado no diagrama do bug

| tentativa | arquitetura (`flowchart TB`) | módulos (`graph LR`) |
|---|---|---|
| alpha.6, perfil canônico | `routes crossing reserved graph geometry` | igual |
| alpha.6, perfil compacto | igual | igual |
| 0.10.0, canônico, compacto e `Auto` | igual | `unroutable graph edges` |
| 0.10.0, teto de trabalho de 20 e de 200 milhões | igual | igual |
| 0.10.0, `graph_padding_x/y` de 3 a 12 e de 2 a 8 | igual | igual |
| 0.10.0, direção da raiz `LR`, `RL`, `BT` | igual | igual (`BT`: `reserved`) |
| 0.10.0, sem as linhas `direction` internas | estoura o teto de 2 milhões (2 000 069); com 8 milhões, `reserved` | igual (2 000 020) |
| 0.10.0, só subgraphs até 1 ou 2 níveis (aninhados achatados) | igual | igual |
| alpha.6, **sem nenhum subgraph** | desenha, 363 x 117 | desenha, 95 x 167 |
| 0.10.0, **sem nenhum subgraph** | desenha, 348 a 372 x 117 (precisa de 4 milhões) | desenha, 95 x 167 |

Conclusão: **nenhuma versão nem opção renderiza o diagrama com os grupos**. O que renderiza é o
mesmo grafo sem as bordas deles, e foi isso que o crate passou a fazer, avisando.

### Os outros modos de falha, medidos no showcase de Mermaid

Todos na `0.10.0`; a alpha tem os mesmos e mais alguns (`Cache~K, V~` na `classDiagram` não
parseia).

| modo | mensagem do merman | reprodução | o que o deckle faz |
|---|---|---|---|
| traços diferentes que se cruzam | `... `mixed-stroke route junctions` ...` | 4 arestas (`---`, `===>`, `o--o`, `x--x`), teste `MIXED_STROKES` | desenha todas como linha comum e avisa |
| subgraphs com `direction` próprio e a grade grande demais | `ASCII resource limit `max_ascii_grid_cells` exceeded during `ascii_layout`: actual 688758, maximum 250000` | pipeline de CI/CD com 3 subgraphs aninhados | desenha sem as bordas e avisa |
| flowchart denso demais | `... `unroutable graph edges` ...` ou `... `max_ascii_layout_work_units` exceeded ...: actual 4000031, maximum 4000000` | 8 camadas x 8 nós, 3 arestas por nó (teste `dense_flowchart`) | erro, nada a tirar |
| aresta que pula uma camada de subgraphs | `routes crossing reserved graph geometry` | subgraphs empilhados (`S12 --> D6` por cima do grupo do meio, `GW --> O1`...), de 37 a 53 nós | desenha sem as bordas e avisa quando o teto não estoura antes |
| `state`, composto com transição de volta | `... `routes crossing reserved graph geometry` for `state` yet` | `A { [*] --> B; B --> C; C --> B }` | erro (sem degrau) |
| `state`, composto que sai para outro estado | igual | `A { [*] --> B; B --> [*] }; A --> D` | erro |
| `state`, dois compostos, composto dentro de composto, composto sem `[*]`, concorrência `--` | igual | ver `docs/adr/0002` e o showcase | erro |
| `state`, composto **simples** | desenha | `X --> A`, `A { [*] --> B --> C --> D --> [*] }`, `A --> [*]` | desenha |

Um flowchart plano (sem subgraphs) de **54 nós e 72 arestas** em nove camadas (o do showcase)
desenha em 117 x 89, em 22 ms, **com o teto padrão de 2 milhões**. Um de 56 nós e 77 arestas
passa de 2 milhões e desenha com 4. O pior caso é o merman gastar o teto inteiro procurando uma
rota que não existe: 26 ms com 2 milhões, 43 ms com 4, 72 ms com 8, 162 ms com 20 (release).
Subir o teto não ajuda esses diagramas, só os que realmente precisam de mais trabalho.

### Benchmark do flowchart grande (V5, `make bench`)

Mesmo teste (`bench_flowchart`), mesma máquina, release, `cargo test --release`; 4 rodadas de
cada lado, e a mediana de cada rodada (50 execuções do médio, 15 dos grandes). A máquina é
barulhenta (o "grande e fundo" é bimodal), então o intervalo entre rodadas vale mais que um número:

| caso | alpha.6 (`bcc99f8`) | 0.10.0 |
|---|---|---|
| médio, 6 arestas | 1,48 a 1,55 ms | 1,43 a 1,46 ms |
| grande e fundo, 48 arestas, 405 linhas | 29 a 49 ms (menor mínimo: 28 ms) | 18 a 30 ms (menor mínimo: 17 ms) |
| grande e largo, 48 arestas, 45 linhas | 16,5 a 24,9 ms (menor mínimo: 16 ms) | 15,7 a 19,6 ms (menor mínimo: 15 ms) |

A `0.10.0` não piorou o benchmark. O render do `examples/mermaid.md` inteiro (24 blocos) está no
teste do job `native`, com orçamento de 5 s e o cache acertando na segunda passada.

### O degrau de simplificação, nos blocos que falhavam

| bloco | como escrito | sem traço | sem subgraphs | os dois |
|---|---|---|---|---|
| 14 formas e 8 tipos de aresta | `mixed-stroke` | **desenha** | `mixed-stroke` | desenha |
| CI/CD, subgraphs aninhados com `direction` | `max_ascii_grid_cells` | igual | **desenha** | desenha |
| ILZA, arquitetura | `reserved` | igual | **desenha** (com 4 milhões) | desenha |
| ILZA, módulos | `unroutable` | igual | **desenha** | desenha |
| plataforma, 37 nós e 6 subgraphs empilhados, com arestas que pulam subgraph | `max_ascii_layout_work_units` (4 000 005) | igual | igual | igual: o bloco do showcase virou um flowchart plano de 54 nós |

### Não foi medido

A `0.8.0` estável; a legibilidade do diagrama do bug achatado (348 colunas) numa janela
estreita; o preview numa UI de terminal de verdade; o degrau de simplificação para o `state`
(o modelo é uma árvore de documentos, e achatar o composto mudaria o significado dos `[*]`).

---

## V6 — O scanner de Markdown aborta o Neovim com aninhamento fundo

**Por quê importa:** é o mesmo modo de falha de V2 (processo morto, trabalho não salvo
perdido) vindo de onde ninguém espera: um `.md` com listas e citações aninhadas.

Neovim 0.11.5, parser `markdown` do core, texto entregue a `get_string_parser(...):parse(true)`:

```
nvim: lib/src/parser.c:410: ts_parser__external_scanner_serialize: Assertion `length <= 1024' failed.
exit code: 134
```

`pcall` **não** captura: é `assert` em C. O estado do scanner externo (a pilha de blocos
abertos, cerca de 1 byte por contêiner) passa de 1024 bytes. Limiar medido em processos
separados, com `n` repetições da forma e o número de contêineres abertos entre parênteses:

| forma | passou | abortou |
|---|---|---|
| `- > ` × n, numa linha (2n) | n=100 (200) | n=128 (256) |
| `> ` × n, numa linha | n=200 | n=256 |
| `- ` × n, numa linha | n=200 | n=256 |
| item aninhado por recuo de 2 colunas, n linhas | n=200 | n=256 |
| item ordenado aninhado por recuo de 3 colunas, n linhas | n=200 | n=256 |
| `> ` × k na linha k, n linhas | n=200 | n=256 |
| só espaços de recuo (sem marcador), até 800 colunas | passou | — |

O limiar é entre 200 e 256 contêineres abertos, e não depende da forma. Recuo sem marcador
não abre contêiner. Tempo de parse não é o problema: o caso que passa mais lento levou 10ms.

**Consequência em `lua/deckle/parse.lua`:** antes de chamar o treesitter, uma varredura de uma
passada estima, por excesso, quantos contêineres cada linha abre (marcadores `>` e de lista,
mais 1 nível por 2 colunas de recuo antes de um marcador). Acima de 64 (`MAX_NESTING`, mais
de 3 vezes de folga em relação ao limiar) o documento inteiro cai no caminho cru: um
`paragraph` por trecho entre linhas em branco. Os testes rodam nove casos patológicos (sete
formas) num Neovim filho e não são vacuosos: com `MAX_NESTING` desligado, `- > ` × 300
derruba o processo com exit 134.

**Não foi medido:** o limiar em Neovim 0.11.0 e nightly (a guarda não depende dele, e os
testes passam nos três), nem se existe outra combinação de entrada que dispare outro
`assert` do mesmo scanner. O fuzz de 600 documentos da suíte não achou nenhuma.

---

## V7 — Custo do parser

Neovim 0.11.5, `parse_lines` sobre os fixtures repetidos até 5124 linhas (1484 blocos, todos
os tipos): **110ms** no total, de uma vez e com o treesitter incluído. Um bloco de código de
2000 linhas: **14ms**. A fase 2 re-renderiza com debounce; o parse sozinho não precisa de cache.

---

## V8 — Clusters, largura e custo do render (fase 2)

**Por quê importa:** o wrap por largura de display é o que quebra implementação de preview com
emoji e CJK, e o render roda a cada `TextChanged` com debounce.

Neovim 0.11.0, 0.11.5 e nightly (0.13.0-dev), com resultado idêntico nos três:

- `vim.fn.split(s, "\\zs")` devolve uma sequência com ZWJ (👨‍👩‍👧, 18 bytes) como **um** cluster
  de `strdisplaywidth` 2. Cinco delas em sequência dão cinco clusters de 2. Emoji com tom de
  pele e com VS16 (❤️) também saem como um cluster de 2. Um acento combinante fica com a letra.
- `strdisplaywidth`: emoji 2, CJK 2, `•` `─` `│` 1 (com `ambiwidth=single`; com `double` o
  `render/rule.lua` divide a largura pela do glifo).
- Custo de `render.render` sobre os fixtures repetidos até 5103 linhas de fonte (1269 blocos,
  4616 linhas de preview, 3132 marcas): **24 a 28ms**, contra ~110ms do parse (V7). O README do
  projeto (90 linhas): **~0.8ms**. Um parágrafo de 20000 palavras: 13 a 23ms. Um parágrafo CJK
  de 35000 caracteres: 32 a 36ms.

**Não foi medido:** nada numa UI de terminal de verdade. Os testes de preview são headless, e
`TextChanged`, `InsertLeave` e `WinResized` reais são exercitados com teclas enviadas por RPC
(`child.type_keys`). Fora de uma tecla, num Neovim sem UI, `WinResized` não dispara.

---

## V9 — Distribuição: o módulo carrega em cinco dos seis alvos (fase 8)

**Por quê importa:** a seção 12 admitia que macOS e Windows nunca tinham sido testados, e o
`-undefined dynamic_lookup` do macOS era o risco declarado da fase 8.

Rodada do `release.yml` no PR da fase 8, em runners do GitHub, Neovim 0.11.0, rustc 1.95.0, com
`cargo build --release --locked`. Em cada alvo marcado "sim", o smoke test
(`tests/native/install_smoke.lua`) instalou o artefato pelo instalador de verdade (`file://`,
checksum conferido), carregou por `package.loadlib` no caminho de `info()` e passou toda a
bateria de `native_headless.lua`, inclusive "erro em Rust não derruba o processo".

| Alvo | Runner | Compila | Carrega no Neovim |
|---|---|---|---|
| `x86_64-unknown-linux-gnu` | ubuntu-24.04 | sim | sim |
| `aarch64-unknown-linux-gnu` | ubuntu-24.04-arm | sim | sim |
| `x86_64-apple-darwin` | macos-15-intel | sim | sim |
| `aarch64-apple-darwin` | macos-15 | sim | sim |
| `x86_64-pc-windows-msvc` | windows-latest | sim | sim |
| `aarch64-pc-windows-msvc` | windows-latest (cross) | sim | **não testado** |

Achados:

- **macOS:** as flags de `.cargo/config.toml` bastam. O `.dylib` carrega se for instalado como
  `deckle_native.so`; o `package.cpath` do LuaJIT não procura `.dylib`.
- **Windows:** o mlua com `module` usa `raw-dylib` e importa de `lua51.dll`
  (`mlua-sys` 0.10.0, `build/main_inner.rs`), então não precisa de import lib. Carregou no
  `nvim.exe` oficial 0.11.0 sem nenhum ajuste. O aarch64 compila por cross-target pelo mesmo
  caminho, mas não há como executá-lo na CI.
- **Runners:** `macos-13` e `macos-14` não existem mais ("The configuration
  'macos-14-arm64-us-default' is not supported"). Tempo de compilação sem cache: Linux 2 a 3 min,
  Windows ~3 min, macOS x86_64 ~8 min.
- **`vim.fn.sha256` não aceita binário:** `E976: Using a Blob as a String` com byte NUL
  (Neovim 0.11.5). O hash do instalador é `lua/deckle/sha256.lua`, em Lua puro: 10,5 MB em
  0,15 s, o mesmo que o `sha256sum`, com o mesmo resultado.
- **Publicação:** os 12 arquivos baixados da rodada (6 binários e 6 `.sha256`) passam em
  `sha256sum -c`, que é a conferência que o job `release` faz antes de publicar. O próprio
  job `release` só roda em tag e não foi exercitado.

**Não foi medido:** Neovim diferente do 0.11.0 nos runners; Alpine (musl); o tempo de download
em rede lenta. O `.so` de Linux x86_64 tem 10,5 MB (build local); no workflow, os artefatos
saem compactados com 4,0 a 4,5 MB, e o tamanho de cada binário descompactado nos outros alvos
não foi registrado.

---

## V10 — Highlight de code block com parser de string (fase 5)

**Por quê importa:** o buffer de preview não tem `filetype=markdown`, então a injeção do
treesitter não acontece sozinha. O highlight é refeito à mão com `get_string_parser` e a query
`highlights`, a cada render, e o que a API devolve de verdade define como isso degrada.

Neovim 0.11.0, 0.11.5 e nightly (0.13.0-dev), com resultado idêntico nos três, salvo os tempos:

- `vim.treesitter.language.get_lang(nome)` devolve **o próprio nome** quando nada foi
  registrado: `sh`, `js`, `py`, `rs`, `yml` e `viml` voltam iguais. Alias não vem de graça, é
  preciso uma tabela. `vim.filetype.match({ filename = "x.py" })` acha `python` e
  `x.sh` devolve `nil` (o shell depende do conteúdo).
- `language.add(lang)` de parser ausente **não lança**: devolve `nil, 'No parser for language
  "x"'` (com `pcall`: `true, nil, msg`). Com parser, devolve `true`. `get_string_parser` na
  mesma situação **lança**. `query.get` de linguagem sem parser devolve `nil`.
- `parser:parse()` sem argumento devolve a árvore da linguagem do bloco e `children()` vazio.
  `parse(true)` roda as injeções (Lua com `vim.cmd([[ ]])` ganha um filho `vim`). Sem o `true`,
  nenhum outro parser é carregado por causa de um bloco de código.
- As capturas de `lua` chegam como `keyword`, `variable`, `operator`, `string`, `comment`,
  `keyword.return`, `number`, com `metadata` vazio.
- Custo de um bloco de Lua denso (21 capturas por linha), `render.render` inteiro, em
  Neovim 0.11.0, 0.11.5 e nightly: o parse de 6000 linhas leva ~16 a 21 ms e o laço de
  `iter_captures` (44 mil capturas), ~105 ms, que é o que domina.

  | bloco | a frio | com cache |
  |---|---|---|
  | 100 linhas | 9 a 10 ms | 0.2 a 0.5 ms |
  | 2000 linhas (42 mil marcas de captura) | 115 a 131 ms | 9 a 14 ms |
  | 5000 linhas (105 mil marcas de captura) | 397 a 445 ms | 30 a 49 ms |
  | 2000 linhas, linguagem sem parser | 4 a 5 ms | |

  O teto de 5000 linhas (`MAX_HIGHLIGHT_LINES`) vem daí: acima dele o custo a frio passa de
  meio segundo, e o preview re-renderiza a cada edição.

**Não foi medido:** parser de terceiros (só `lua`, `c` e `vim` vêm com o Neovim), se algum
deles tem `assert` no scanner como o de Markdown (V6), e o tempo numa UI de terminal.

---

## Como reproduzir

Os spikes vivem em `/tmp` e são descartáveis. Para refazer:

```sh
cargo new --lib spike && cd spike
# Cargo.toml: crate-type = ["cdylib"], mlua = { version = "0.11", features = ["module","luajit"] }
cargo build --release
mkdir -p rtp/lua && cp target/release/libspike.so rtp/lua/spike.so
nvim --headless -u NONE --cmd "set rtp+=$PWD/rtp" -l teste.lua
```

**Sempre confira o exit code** (`134` = abortou) e **sempre trave o script se o build
falhar** — um `.so` velho faz o teste passar com `attempt to call a nil value`, que parece
sucesso e não é. Esse falso positivo aconteceu duas vezes durante esta validação.
