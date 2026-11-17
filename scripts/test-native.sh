#!/usr/bin/env bash
# Compila o `.so` e roda o teste headless do modulo nativo.
#
# Uso:
#   scripts/test-native.sh
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
  0) echo "test-native: ok (exit 0)" ;;
  134)
    echo "test-native: nvim ABORTOU (SIGABRT, exit 134)." >&2
    echo "  Isto e o processo do Neovim morrendo (V2), nao falha de assercao." >&2
    ;;
  *) echo "test-native: falhou (exit ${status})" >&2 ;;
esac

exit "${status}"
