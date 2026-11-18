# ADR-0005 — Piso de versão do Neovim em 0.11.0

**Status:** aceito · **Data:** 2026-11-17

## Contexto

O roadmap tratava o piso de versão como suposição: a validação inicial só tinha o Neovim 0.11.5
na máquina, então "0.11 ou mais novo" era o que se sabia funcionar, e o 0.10 ficou como
pergunta. A fase 0 levou o 0.10.4 à CI como job permissivo (que podia falhar sem reprovar o PR)
justamente para medir, e a decisão ficou registrada na seção "Decisões ainda em aberto" do
[roadmap](../roadmap.md) até a fase 10, que a promove a ADR.

## Decisão

**Neovim 0.11.0.** É a versão mínima suportada, e o plugin se recusa a rodar abaixo dela:

- `plugin/deckle.lua` não registra `:Deckle` e avisa
  `deckle.nvim requires Neovim 0.11.0 or newer`, em vez de deixar o usuário descobrir pelo
  primeiro erro de `vim.validate`;
- `:checkhealth deckle` mostra a versão em uso e o piso, com erro abaixo dele.

## Razão

Medido, não deduzido:

- **0.10.4 reprova.** Na CI da fase 0, 20 dos 39 casos da suíte falharam. A causa não é bug de
  lógica: `deckle.config` valida a configuração com `vim.validate` na **assinatura nova**
  (`vim.validate(name, value, validator, optional, message)`, do 0.11), que o 0.10 não tem, e a
  guarda do `plugin/deckle.lua` faz todo teste de despacho bater em `E492` (comando não
  existe). O job saiu da matriz em vez de ficar permanentemente vermelho.
- **0.11.0 passa, e é o piso exato.** A matriz da CI roda a suíte inteira em `v0.11.0` e em
  `nightly`, e o job `native` (o `.so` de verdade) nas mesmas duas. A distribuição foi medida
  num Neovim 0.11.0 em Linux x86_64 e aarch64, macOS x86_64 e arm64 e Windows x86_64 (V9 em
  [validation.md](../validation.md)). Testar no piso exato, e não numa 0.11.x mais nova, é o que
  faz o número dizer algo.
- **0.11.5** é a versão da máquina de desenvolvimento, onde V1 a V7 foram medidos e V8 e V10
  foram repetidos. O nightly (0.13.0-dev na fase 5) deu resultado idêntico nas medições de V8 e
  V10, salvo os tempos.

A forma nova de `vim.validate` também é a que o 0.11 recomenda: a de tabela está depreciada.
Usá-la só para o 0.10 seria escrever código novo contra a API que o Neovim está aposentando.

## Alternativas descartadas

- **Piso em 0.10.** Exigiria trocar `vim.validate` por uma forma que valha nas duas versões
  (ou por validação própria), mais o job do 0.10 de volta à CI como obrigatório, e consertar o
  que mais aparecesse: 20 casos falhando é o que se viu, não o que existe por baixo deles. Sem
  usuário pedindo e sem medida do que mais quebra, é custo sem retorno.
- **Piso em uma 0.11.x mais nova que a 0.11.0.** A suíte passa no piso exato, então nada indica
  que o código use uma API posterior a ele, e um piso mais alto excluiria gente sem ganho.

## Consequências

- Quem está no 0.10 ou antes não tem o plugin, e recebe uma mensagem que diz por quê.
- A CI continua com `v0.11.0` e `nightly`. Subir o piso é mudar o número no `plugin/deckle.lua`,
  no `health.lua`, na matriz da CI, no README e no `doc/deckle.txt`. A suíte de documentação
  (`tests/test_doc.lua`) falha se o `plugin/deckle.lua`, o `health.lua`, o README ou o
  `doc/deckle.txt` divergirem do piso; a matriz da CI fica por conta de quem sobe o número.
- Baixar o piso é uma decisão nova, com um ADR que o substitua, não um ajuste.
- O que segue sem medida: o Neovim entre 0.11.1 e 0.11.4 (só a 0.11.0 e a 0.11.5 foram
  exercitadas) e qualquer versão estável acima da 0.11.5 (só o nightly foi). O piso é o que foi
  exercitado, não uma garantia sobre cada versão acima dele.
