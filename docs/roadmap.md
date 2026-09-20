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
- **macOS e Windows.** Nada foi testado. A fase 8 é a primeira que descobre.
- **Versão do merman.** O pin de `0.8.0-alpha.6` veio da validação de 2026-09-06. Reconferir
  na fase 6.
- **Sobrevivência da camada 2.** Decidir depois da v0.2.0, com uso real na mão.
