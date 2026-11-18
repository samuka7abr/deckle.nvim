#!/usr/bin/env bash
# Compila o `.so` e roda tudo que exige o modulo nativo:
#
#   1. tests/native/native_headless.lua: o crate dentro do Neovim, e o processo sobrevive a
#      erro de Rust (regressao de V2.2, fase 6);
#   2. tests/native/test_mermaid_native.lua (mini.test): o mermaid no preview com o `.so` de
#      verdade, o gate de saida da fase 7.
#
# Uso:
#   scripts/test-native.sh
#
# Os casos do item 2 sao pulados com aviso quando `lua/deckle_native.so` nao existe, e e assim
# que se comportam no job `test` da CI, que nao tem Rust. Aqui o `.so` e a razao de ser do
# script: `DECKLE_REQUIRE_NATIVE=1` transforma o pulo em falha.
#
# Trava no primeiro erro de proposito: um `.so` velho faz o teste passar com
# `attempt to call a nil value`, que parece sucesso e nao e. `make native` remove o `.so`
# antigo antes de compilar, entao build quebrado = script quebrado, sem `.so` no lugar.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
repo_root="$(cd -- "${script_dir}/.." >/dev/null 2>&1 && pwd -P)"
cd "${repo_root}"

make native

if [[ ! -f lua/deckle_native.so ]]; then
  echo "test-native: lua/deckle_native.so nao existe depois de 'make native'" >&2
  exit 1
fi

# `-u NONE` + rtp so com o repo: nenhum plugin nem config do usuario entra no teste.
status=0
nvim --headless -u NONE --cmd "set rtp^=${repo_root}" -l tests/native/native_headless.lua || status=$?

case "${status}" in
  0) echo "test-native: native_headless ok (exit 0)" ;;
  134)
    echo "test-native: nvim ABORTOU (SIGABRT, exit 134)." >&2
    echo "  Isto e o processo do Neovim morrendo (V2), nao falha de assercao." >&2
    exit "${status}"
    ;;
  *)
    echo "test-native: falhou (exit ${status})" >&2
    exit "${status}"
    ;;
esac

# O mermaid no preview, com o `.so` de verdade. `scripts/test.sh` ja trata o exit 134 e baixa o
# mini.nvim se faltar.
DECKLE_REQUIRE_NATIVE=1 ./scripts/test.sh tests/native/test_mermaid_native.lua
echo "test-native: ok"
