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
