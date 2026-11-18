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

## V11 — merman 0.8.0, subgraphs, cor e saída suja (branch `fix/mermaid-showcase`)

**Por quê importa:** dois diagramas reais do usuário (o ILZA: uma arquitetura com 11 subgraphs
aninhados, 8 deles com `direction`, e um mapa de módulos com 9 subgraphs) não renderizavam, e o
showcase novo precisava saber o que o merman faz de verdade antes de prometer cobertura.
Medido em 2026-11-17 e 2026-11-18, rustc 1.95, Linux x86_64.

### Os diagramas do ILZA falham em toda versão do merman

Mesmos dois arquivos (`crates/deckle-native/tests/fixtures/ilza_*.mmd`), quatro versões:

| versão | resultado |
|---|---|
| `0.8.0-alpha.6` | `routes crossing reserved graph geometry` |
| `0.8.0` | `routes crossing reserved graph geometry` |
| `0.9.4` | `routes crossing reserved graph geometry` e `unroutable graph edges` |
| `0.10.0` | `routes crossing reserved graph geometry` e `unroutable graph edges` |

- **Origem:** `merman-ascii/src/graph/routing.rs`. Uma aresta que cruza a borda de um
  `subgraph` tem poucos candidatos de rota, e quando nenhum passa, o renderer desiste do
  grafo inteiro. Nenhuma opção pública contorna: o perfil `Compact` (medido, nos dois
  diagramas, na 0.8.0) falha igual.
- **Menor caso** (ddmin, `tools/ddmin.py` do laboratório): nove linhas. Uma aresta que sai de
  um subgraph e entra no **primeiro** nó de outro falha; no segundo nó, o merman roteia.

  ```
  flowchart TB
    subgraph API
      h1[h1]
    end
    subgraph Temporal
      t1[t1]
      t2[t2]
    end
    API --> t1        %% falha; `API --> t2` desenha
  ```
- **Achatar resolve.** Tirar as linhas `subgraph`, o `end` e o `direction` de dentro faz os
  dois renderizarem nas quatro versões. Medido com o fallback do plugin (`flatten.rs`): o mapa
  de módulos sai com 95 colunas por 167 linhas, e a arquitetura com 326 colunas por 117 linhas
  (363 por 117 quando o subgraph citado por uma aresta é trocado pelo primeiro nó dele, em vez
  de virar um nó com o título: o plugin escolheu o nó com título, que não desloca os índices do
  `linkStyle` e diz o que a aresta liga). O resultado carrega `simplified = "subgraphs"` e o
  preview mostra a nota `mermaid: layout simplified (subgraphs flattened)`. O mesmo vale para
  estado composto aninhado com transição (`routes crossing reserved graph geometry` para
  `state`), que vira `(composite states flattened)`.
- Custo do fallback (o render que falha mais o achatado), release: **~51 ms** a arquitetura
  e **~21 ms** o mapa de módulos; em debug, ~140 ms o mapa de módulos. O cache do plugin
  guarda o resultado, então isso é pago uma vez por diagrama e largura.

### 0.8.0 contra a alpha.6, e por que não a 0.10.0

- A 0.8.0 compila com o `render.rs` da alpha.6 **sem mudar uma linha**, mas só com
  `features = ["all-diagrams"]` nos dois crates: sem elas o parser de flowchart não é compilado
  e o tipo some. A 0.8.0 tem o 15º tipo, `swimlane` (que se escreve `swimlane-beta`).
- A 0.10.0 pede porte de API (`SemanticParser` e `render_parsed_report`, crate `merman-model`)
  e regride o roteamento: **não entrou**.
- Benchmark do `make bench` (mediana, release, mesma máquina, os mesmos grafos). As duas
  primeiras colunas rodam o `render.rs` original; a terceira é o código desta branch (tema de
  cor, limpeza de entidades e fallback já ligados, em modo Plain). Uma rodada por coluna, então
  a diferença de poucos ms entre a 2ª e a 3ª é ruído:

  | caso | alpha.6 | 0.8.0 | esta branch |
  |---|---|---|---|
  | flowchart médio (6 arestas) | 1,66 ms | 1,37 ms | 1,25 ms |
  | grande e fundo (48 arestas, 405 linhas) | 53,0 ms | 28,0 ms | 20,3 ms |
  | grande e largo (48 arestas, 45 linhas) | 24,1 ms | 12,4 ms | 16,6 ms |

### Matriz de recursos na 0.8.0

151 casos (formas, arestas, subgraphs, estilos, entidades e os 15 tipos), cada um renderizado
na alpha.6, na 0.8.0 e na 0.10.0; na 0.8.0, **141 desenham** e 10 não:

| caso | resultado na 0.8.0 |
|---|---|
| `@{ shape: cloud }`, `@{ shape: bolt }` | `unsupported diagram: ASCII rendering does not support `unsupported flowchart node shape projections` for `flowchart` yet` |
| `@{ shape: naoexiste }` | `mermaid parse error: Diagram parse error (flowchart-v2): No such shape: naoexiste.` |
| generics aninhados em class (`List~Pair~K,V~~` com relação) | `mermaid parse error: Diagram parse error (classDiagram): Unexpected character at 93` |
| ER com alias (`CUSTOMER["Cliente"]`) | `mermaid parse error: Diagram parse error (er): unexpected only one; expected ...` |
| composto dentro de composto, em state | roteamento: **conserta o fallback** |
| `pie`, `quadrantChart`, `c4`, `block` | `unsupported diagram: ASCII rendering does not support diagram type `<tipo>`` |

Desenham, mas com defeito, e **não** são erro:

- Paralelogramo `[/ x /]` e `lean-r`: o desenho sai torto (a moldura inclinada se sobrepõe).
- Nó losango `{x}`: a caixa sobreposta de V5.

### Texto que o merman escreve a mais: o `bytes=`

O merman-ascii 0.8.0 tem um mecanismo de **divulgação do texto autoral**: quando o texto que
ele desenha não é, byte a byte, o que o autor escreveu (HTML decodificado, quebra de linha,
espaço normalizado, rótulo diferente do id), acrescenta ao desenho uma linha com o original,
como `text(bytes=12)="Box<T>"`. **Não há opção** que o desligue (`AsciiRenderOptions` tem
`relation_summary_diagnostics`, que não é isso e já vem `false`), e o formato não é estável o
bastante para filtrar por regex sem pegar rótulo legítimo. **Registrado como limitação, não
filtrado.** Onde aparece:

| diagrama | quando |
|---|---|
| ER | **sempre** que a entidade tem atributo: cada um sai `type(bytes=3)="int" name(bytes=2)="id" keys=[] comment(bytes=0)=""` (`er/render.rs`) |
| class | rótulo diferente do id (`Box~T~` sai `Box<T>`, mais `text(bytes=..)` e `id(bytes=..)`) e relação que cruza `namespace` (`member(bytes=..)`) |
| xychart | com `title` ou título de eixo (`titleDisplay: chart(bytes=6)="Vendas"`) e com mais de uma série ou valor que a grade não representa exato (`values: █ series=0 ... samples=[...]`) |

Um xychart de uma série só, sem título, com valores que caem na grade de 5 linhas (múltiplos
de 20 num eixo de 0 a 100), sai sem nenhuma linha extra.

### Entidades HTML

Em flowchart e state, `&lt;` fica literal no rótulo. A causa não é falta de decodificação: o
merman decodifica entidades (`&gt;`, `&amp;`, `&quot;`, `&apos;` e o `#9829;` do Mermaid saem
certos), mas devolve `<` como `&lt;` (a saída dele é pensada para HTML), e a caixa já foi
dimensionada para os 4 caracteres. O `clean.rs` decodifica `&lt;`, `&gt;`, `&amp;`, `&quot;` e
`&#39;` nas linhas prontas, devolvendo as células poupadas como espaços ao redor do texto do
nó (centralizado continua centralizado), e passa por todos os 15 tipos. Dois casos que a
limpeza **não** conserta:

- `&#39;` sai `&'`: o merman consome o `#39;` como código de entidade do Mermaid e deixa o
  `&`. Escreva `#39;` (que sai `'`).
- `&amp;lt;` já sai `&lt;` do merman, e a limpeza o decodifica de novo: aparece `<`.

### Cor

Em TrueColor o merman pinta **todo** elemento com a cor do papel no tema dele, não só o que o
diagrama estiliza: um `flowchart` sem `classDef` sai com texto `#27272a`, borda `#a1a1aa` e
seta `#52525b`, de um tema claro, que iriam por cima de qualquer esquema escuro. Honra
`classDef` (`fill`, `stroke`, `color`), `style`, `linkStyle`, `box rgb(...)` e `rect rgb(...)`.
O crate monta um tema em que todo papel "de moldura" tem uma cor-sentinela e tira os escapes
dela das linhas: sobra só a cor que o diagrama pediu, e as séries do xychart. Medido: com a
cor, o texto sem escapes é **idêntico** ao do modo Plain (linha por linha, nos 15 tipos, nos
dois ILZA, em largura 40 e 120). O fundo de um nó estilizado cobre as bordas e os espaços,
mas não as células de texto (o merman emite o texto só com a cor de frente).

### Não foi medido

- O desenho colorido num terminal de verdade (só o texto e as marcas, em Neovim headless).
- O custo do fallback em release foi medido uma vez por diagrama (acima), sem repetições.
- macOS e Windows com as dependências novas da 0.8.0 (`dugong`, `lol_html`, `cssparser`): o
  `Cargo.lock` as resolve, e a CI de release as compila, mas nada as executou nesses alvos
  fora da CI.

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
