#!/usr/bin/env bash
# Roda a suíte de testes (mini.test) em `nvim --headless`.
#
# Uso:
#   scripts/test.sh                        roda tudo
#   scripts/test.sh tests/test_config.lua  roda um arquivo só
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
repo_root="$(cd -- "${script_dir}/.." >/dev/null 2>&1 && pwd -P)"
cd "${repo_root}"

deps_dir=".deps"
mini_dir="${deps_dir}/mini.nvim"

if [[ ! -d "${mini_dir}" ]]; then
  echo "[deps] baixando mini.nvim em ${mini_dir}"
  mkdir -p "${deps_dir}"
  git clone --filter=blob:none --depth 1 --branch stable \
    https://github.com/echasnovski/mini.nvim "${mini_dir}"
fi

# O driver lê daqui em vez de receber por `-c`, para não ter que escapar path em Lua.
export DECKLE_TEST_FILE="${1:-}"

status=0
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "luafile scripts/run.lua" \
  -c "qa!" || status=$?

case "${status}" in
  0) ;;
  134)
    echo "scripts/test.sh: nvim ABORTOU (SIGABRT, exit 134)." >&2
    echo "  Isto nao e falha de teste: e o processo do Neovim morrendo." >&2
    ;;
  124)
    echo "scripts/test.sh: timeout (exit 124) ao rodar os testes." >&2
    ;;
esac

exit "${status}"
