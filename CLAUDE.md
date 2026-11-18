# deckle.nvim

Preview de Markdown num buffer separado somente-leitura dentro do Neovim. Lua faz tudo que
encosta na API do editor. Um `.so` opcional em Rust (via mlua) renderiza Mermaid em arte de
texto usando o crate `merman`.

**Estado: fases 0 a 10 do roadmap entregues** (só falta a tag `v0.3.0`, que o roadmap manda sair
com a fase 10; nenhuma tag foi criada até aqui). Existem `lua/deckle/` (`init`, `config`,
`health`, `parse`, `preview`, `sync`, `highlight`, `native`, `install`, `sha256`, `version`,
`caps`, `image/` com `init`, `kitty` e `png`, e `render/` com um módulo por tipo de bloco, mais
`mermaid` e `image`), `plugin/deckle.lua`, `doc/deckle.txt` (o `:help`, escrito à mão),
`examples/showcase.md`, `tests/` (mini.test), `scripts/`, o crate `crates/deckle-native/` com
`Makefile`, a CI e o workflow de release.

`:Deckle open|close|toggle|refresh|health|install` funcionam. Camada 0: texto, tabelas, código
colorido por treesitter e html cru. Camada 1: Mermaid como arte de texto, pelo `deckle_native`
(`deckle.native.get()`, `deckle.install.info()` diz onde está o binário e de onde veio). Camada 2:
imagem PNG local por Unicode placeholders do protocolo do kitty (kitty e ghostty), com a detecção
em `caps.lua`; iTerm2 e sixel são detectados e saem como texto alternativo. A camada 3 (`mmdc`)
não existe. O cursor do fonte e o do preview se seguem (`sync.lua`, `sync = "cursor"`): a busca
binária sobre o mapa `preview -> fonte` do render é pura, e o anti-loop são dois mecanismos (flag
reentrante e linha esperada por lado, ver o topo do módulo). Dois contratos em LuaCATS, de que o
resto depende: o IR no topo de `parse.lua` e o render (módulo por tipo, `ctx`, marcas, mapa) no
topo de `render/init.lua`. Mudar um campo lá é mudar o contrato. Confira que um comando existe
antes de rodá-lo.

**A documentação é conferida por teste** (`tests/test_doc.lua`). Opção nova em `config.lua` (e em
`known_keys`), grupo novo em `highlight.lua`, subcomando novo em `init.lua`, evento novo em
`preview.lua` e alvo novo em `install.lua` sem entrada no `doc/deckle.txt` falham a suíte, e o
bloco de valores de fábrica do `doc/deckle.txt` e o do README têm que ser iguais a
`config.defaults()`. A captura do README é a saída real do render, conferida com o `.so`
(`tests/native/test_docs_native.lua`). O `examples/showcase.md` é renderizado pela suíte e tem que
continuar exercitando todo tipo de bloco. O `examples/mermaid.md` (um diagrama grande de cada um
dos 14 tipos, os dois do README do ILZA e um `pie`) é o teste do Mermaid: o `cargo test` renderiza
cada bloco dele, e o job `native` abre o arquivo no preview e exige que nenhum bloco degrade,
salvo o `pie` (`tests/native/test_mermaid_showcase_native.lua`).

## Leia antes de decidir

- `docs/architecture.md` (camadas, pipeline, contrato Lua↔Rust, estrutura de diretórios)
- `docs/roadmap.md` (fases, entregas, gates de saída, anti-escopo)
- `docs/validation.md` (o que foi medido; os números vêm daqui)
- `docs/adr/` (as cinco decisões travadas)

A seção 12 da arquitetura lista o que **não** foi validado. Não trate nada dela como fato.

## Idioma

Documentação, comentários, commits e PRs em **português**. Nomes de código, símbolos e
mensagens de erro do plugin em inglês.

## Regras que vêm dos ADRs

Quebrar qualquer uma destas invalida uma decisão já tomada. Se for realmente necessário,
escreva um ADR novo antes de escrever o código.

1. **O buffer fonte é intocável.** Nenhum extmark, nenhum conceal, nenhum `modifiable = false`
   nele. Todo render vai para o buffer de preview. (ADR-0003)
2. **Rust nunca chama a API do Neovim.** O contrato é `String` entra, `Vec<String>` sai. É o
   que mantém o crate testável com `cargo test` puro. (ADR-0001)
3. **No Rust, sempre `Err`, nunca `panic!` deliberado.** Os dois viram erro de Lua capturável
   com mlua, mas só o `Err` produz mensagem útil. (V2.2)
4. **Nada de `nvim-oxi`.** Com ele, retornar `Err` aborta o processo do Neovim, exit 134,
   trabalho não salvo perdido. Medido. (ADR-0001, V2)
5. **Todo caminho de degradação precisa de teste que force a degradação.** Remover o `.so`,
   passar diagrama inválido, esconder o parser da linguagem. Comentário dizendo que funciona
   não conta. (ADR-0004)
6. **Largura de texto é `vim.fn.strdisplaywidth`, nunca `#str`.** Emoji e CJK entram no teste
   junto com a feature, não depois. **Ressalva (fase 4):** em tabelas, e em qualquer alinhamento
   por coluna, use `vim.api.nvim_strwidth`. O `strdisplaywidth` mede na **janela atual** e, com
   `wrap` ligado, soma uma célula quando um caractere largo cai na última coluna dela. Uma
   célula de CJK mais larga que a janela de quem chamou o render saía maior do que o preview
   (sem `wrap`) desenha, e a linha da tabela ficava curta. O `nvim_strwidth` é a mesma medida
   (emoji, `ambiwidth`, combinantes) sem depender da janela. É o que `render/table.lua` faz, e
   tem teste de regressão.
7. **Índices de linha são 0-indexados com fim exclusivo em todo o IR.** É o que o treesitter e
   a API de buffer usam. Converta nas bordas, nunca no meio.

## Pinos e versões

| | valor | por quê |
|---|---|---|
| Neovim | piso **0.11.0** | medido: o 0.10.4 reprova 20 de 39 casos na CI (ADR-0005) |
| Rust | `rust-toolchain.toml` em **1.95** | MSRV do merman |
| merman-core / merman-ascii / merman-model | `=0.10.0`, **idêntica nos três** | quebra API entre versões; o `OperationControl` mora no `merman-model` (ADR-0002) |

Com rustc 1.93 e um pin frouxo o cargo resolvia merman para `0.7.0-alpha.1` **sem avisar**, e
essa versão não suporta `sequenceDiagram`. O build precisa falhar alto nesse caso, não seguir
em frente: é o `=` do `Cargo.toml`, o `--locked` e o `scripts/check-merman-version.sh`.

## Armadilhas já pagas uma vez

- O cargo gera `libdeckle_native.so`, mas o `require` do Lua só acha `deckle_native.so`. O
  prefixo `lib` some na instalação.
- No macOS o cargo gera `libdeckle_native.dylib`, mas o `package.cpath` do LuaJIT só procura
  `.so`: o binário se instala como `deckle_native.so` lá também (no Windows, `deckle_native.dll`,
  sem prefixo `lib`). O módulo exige `-undefined dynamic_lookup` no link, que vem de
  `.cargo/config.toml`; a variável `RUSTFLAGS` substitui essas flags em vez de somar.
- `vim.fn.sha256` **não serve para binário**: com byte NUL responde `E976: Using a Blob as a
  String`. O hash do instalador é `lua/deckle/sha256.lua`, em Lua puro.
- Nunca escreva por cima de um `.so` em uso: truncar o arquivo mapeado por um Neovim em
  execução derruba o processo. O instalador grava em temporário e troca por `rename`.
- Checksum que não bate aborta a instalação e **não** cai para o cargo. É decisão de
  integridade, e tem teste.
- `lua/deckle/version.lua` é a única fonte da versão do plugin, e a tag da release precisa
  bater com ela (o `release.yml` confere). O instalador monta a URL `v<versão>` a partir dela.
- O `Cargo.lock` é versionado (o crate gera binário distribuído) e todo build de release usa
  `--locked`: é o que impede o cargo de resolver o merman para outra versão sem avisar.
- O merman `0.10.0` não traz família nenhuma por padrão: `merman-core` entra com
  `all-diagrams` e `merman-ascii` com as 14 famílias, uma a uma, **sem** `diagram-swimlane`
  (com ele o `supported_types()` passa a ter 15 e o plugin documenta 14). O `OperationControl`
  vem de `merman-model`, que a `0.10.0` não reexporta.
- O layout de texto do merman **não roteia todo flowchart** (aresta que cruza a borda de um
  subgraph, traços diferentes que se cruzam) **nem todo `state`** (estado composto fora da forma
  mais simples). O crate tem um degrau de simplificação só para o flowchart
  (`render.rs`, "Degrau de simplificacao"): tira o traço, as bordas dos subgraphs ou os dois, e
  devolve `lines, notice`. `render/mermaid.lua` põe o aviso numa linha `DeckleCodeNote` sob o
  desenho, **sem** o prefixo `mermaid:` (que é só da degradação). O `state` que não roteia
  continua erro, e isso está pinado em `render_tests.rs`
  (`only_the_flowchart_has_a_simplification_step`): se uma versão nova rotear, o teste falha e o
  `doc/deckle.txt` ("Limitações conhecidas") tem que mudar.
- Diagrama que não desenha **no showcase** não se esconde: ou ganha o degrau, ou sai do
  `examples/mermaid.md` com a mensagem exata do merman em "Limitações conhecidas".
- Um `.so` velho no lugar faz o teste passar com `attempt to call a nil value`, que parece
  sucesso e não é. Trave o script se o build falhar. Aconteceu duas vezes durante a validação.
- Sempre confira o exit code do `nvim --headless`. **134 é abort**, não falha de teste.
- O buffer de preview não tem `filetype=markdown`, então a injeção de treesitter em code block
  não acontece sozinha. O highlight é refeito à mão com `get_string_parser`.
- O parser de Markdown **aborta o Neovim** (assert no scanner externo, exit 134, sem `pcall`
  que segure) com ~200 contêineres aninhados abertos, p. ex. `- > ` repetido 200 vezes.
  `parse.lua` barra o documento antes de chamar o treesitter. Todo teste que alimenta o
  parser com entrada hostil roda num Neovim filho. (V6)
- `[x]: url` não é reconhecido como definição de link: colide com o item de tarefa `[x]`.
  Não use `x` de rótulo em fixture. Tampouco `- ---` como "item com regra": é uma regra só
  (CommonMark), não uma lista.
- Dividir texto em clusters é `vim.fn.split(s, "\\zs")`: sequência com ZWJ, emoji com tom de
  pele e VS16 saem como um cluster de largura 2. Por byte ou por codepoint o wrap parte o
  emoji ao meio. Largura de um cluster é `strdisplaywidth` dele, e a medida mínima de conteúdo
  é `render.MIN_WIDTH` (10): abaixo dela o conteúdo transborda em vez de virar coluna de uma
  letra.
- Apagar o buffer de preview de dentro do `BufDelete`/`BufWipeout` dele mesmo dá E937 (buffer
  em uso). O `preview.lua` agenda a limpeza para a volta seguinte do laço.
- Em teste com Neovim filho (RPC), `TextChanged` e `WinResized` só disparam quando o laço
  principal anda, e o que o faz andar é uma tecla (`child.type_keys`). `nvim_exec_autocmds`
  entrega o evento sem laço nenhum, e basta para os handlers do preview, que ignoram o
  conteúdo do evento.
- Todo `hl` que um módulo de render escreve nas marcas precisa existir em
  `lua/deckle/highlight.lua`: há teste que varre o código-fonte atrás de `"Deckle..."`. E todo
  grupo de lá precisa de tag `hl-<grupo>` no `doc/deckle.txt`, com o padrão certo.
- `charset = "auto"` vira ASCII com `TERM=linux` ou `dumb`, o que uma CI pode ter. Teste que
  procura um glifo Unicode (`═`, `│`, `┌`) fixa `vim.env.TERM = "xterm-256color"` no Neovim
  filho, em vez de depender do terminal de quem roda. A suíte inteira passa com os três.
- Um `.so` local (`make native`) muda o que a suíte exercita: os casos que exigem o `.so` deixam
  de ser pulados e os de "binário ausente" do `test_health.lua` passam a ser. Rode também sem
  ele (`rm lua/deckle_native.so`) antes de abrir o PR, que é como o job `test` da CI roda.

## Fluxo de trabalho

Uma fase do roadmap é um PR. Branch `feat/f<N>-<slug>` a partir da `main`. PR não entra sem
passar no gate de saída da própria fase, que está escrito no roadmap.

Commits em Angular/Conventional, atômicos, **sem corpo e sem co-autor**.

Fase sem teste é fase não terminada.

## Fora de escopo do projeto inteiro

Não proponha, não implemente, não "deixe preparado para".

- Editar vendo o render ao lado no mesmo texto. Isso é markview.nvim.
- Exportar para HTML ou PDF.
- LaTeX, KaTeX.
- Servidor web, webview, browser.
- Suporte a Vim.
