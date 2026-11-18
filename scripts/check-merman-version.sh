#!/usr/bin/env bash
# Falha se o merman resolver para uma versao diferente da pinada.
#
# Existe por causa de V5: com rustc 1.93 o cargo resolve merman para `0.7.0-alpha.1` SEM
# AVISAR, e essa versao nao suporta `sequenceDiagram`. Com `merman-core` e `merman-ascii` em
# versoes diferentes o crate nem compila. Este script confere o que o cargo de fato
# resolveu, nao o que o Cargo.toml pede.
#
# Ao subir o merman: mude PINNED aqui, os dois pinos em crates/deckle-native/Cargo.toml, o
# ADR-0002 e o CLAUDE.md. Os quatro lugares precisam andar juntos.
set -euo pipefail

PINNED="0.8.0"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "${script_dir}/.."

fail() {
  echo "check-merman-version: $*" >&2
  exit 1
}

# 1. O Cargo.toml tem que pedir a versao exata (`=`) nos dois crates.
for crate in merman-core merman-ascii; do
  declared="$(grep -E "^${crate}[[:space:]]*=" crates/deckle-native/Cargo.toml || true)"
  [[ -n "${declared}" ]] || fail "${crate} nao esta declarado em crates/deckle-native/Cargo.toml"
  [[ "${declared}" == *"\"=${PINNED}\""* ]] \
    || fail "${crate} deveria estar pinado em \"=${PINNED}\" no Cargo.toml, achei: ${declared}"
  # Sem `all-diagrams` o merman 0.8.0 nao compila os parsers: o flowchart some em silencio.
  [[ "${declared}" == *"\"all-diagrams\""* ]] \
    || fail "${crate} precisa de features = [\"all-diagrams\"] no Cargo.toml, achei: ${declared}"
done

# 2. O que o cargo resolveu. `--prefix none` imprime `nome vVERSAO` por linha.
tree="$(cargo tree -p deckle-native --edges normal --prefix none)"

for crate in merman-core merman-ascii; do
  resolved="$(awk -v c="${crate}" '$1 == c { print $2 }' <<<"${tree}" | sort -u)"
  [[ -n "${resolved}" ]] || fail "${crate} nao aparece na arvore do cargo"
  [[ "${resolved}" == "v${PINNED}" ]] \
    || fail "${crate} resolveu para '${resolved}', pinada e v${PINNED}"
done

# 3. Nenhum outro crate `merman-*` pode ter entrado em outra versao.
others="$(awk '$1 ~ /^merman(-|$)/ { print $1 " " $2 }' <<<"${tree}" | sort -u)"
while read -r name version; do
  [[ "${version}" == "v${PINNED}" ]] || fail "${name} resolveu para ${version}, pinada e v${PINNED}"
done <<<"${others}"

echo "check-merman-version: ok, merman em v${PINNED}"
echo "${others}" | sed 's/^/  /'
