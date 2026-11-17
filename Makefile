# Camada 1 (Rust) do deckle.nvim. Ver docs/architecture.md, secao 9.
#
#   make native         compila o crate e instala lua/deckle_native.so
#   make bench          benchmark do flowchart (V5), em release
#   make check-merman   falha se o merman resolver para versao diferente da pinada
#
# Por enquanto so Linux. macOS e Windows entram na fase 8.

CARGO       ?= cargo
TARGET_SO   := target/release/libdeckle_native.so
INSTALLED   := lua/deckle_native.so

.PHONY: native bench check-merman

# O cargo gera `libdeckle_native.so`, mas o `require` so acha `deckle_native.so`: o prefixo
# `lib` some na instalacao (V3). O .so antigo e removido ANTES do build: um binario velho
# no lugar faz o teste "passar" com `attempt to call a nil value`, que parece sucesso e nao
# e (aconteceu duas vezes na validacao). Se o build falhar, o alvo falha e nao sobra .so.
native:
	rm -f $(INSTALLED)
	$(CARGO) build --release -p deckle-native
	test -f $(TARGET_SO) || { echo "make native: $(TARGET_SO) nao foi gerado" >&2; exit 1; }
	cp $(TARGET_SO) $(INSTALLED)
	@echo "make native: instalado $(INSTALLED)"

bench:
	$(CARGO) test --release -p deckle-native -- --ignored --nocapture bench_flowchart

check-merman:
	./scripts/check-merman-version.sh
