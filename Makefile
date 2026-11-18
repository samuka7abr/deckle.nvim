# Camada 1 (Rust) do deckle.nvim. Ver docs/architecture.md, secao 9.
#
#   make native         compila o crate e instala lua/deckle_native.<ext>
#   make bench          benchmark do flowchart (V5), em release
#   make check-merman   falha se o merman resolver para versao diferente da pinada
#   make dump FILE=x    desenha um .mmd e imprime a arte (depuracao)
#
# Linux, macOS e Windows (via MSYS2/Git Bash). Quem nao quer compilar usa `:Deckle install`,
# que baixa o binario da release e so cai para o cargo se nao houver um para a plataforma.

CARGO ?= cargo

UNAME_S := $(shell uname -s 2>/dev/null)

# O cargo gera `libdeckle_native.so` (Linux), `libdeckle_native.dylib` (macOS) e
# `deckle_native.dll` (Windows, sem prefixo). O `require` do Lua so acha `deckle_native.so`,
# e no macOS tambem `.so` (o `package.cpath` do LuaJIT nao procura `.dylib`): o prefixo `lib`
# some na instalacao e o macOS troca a extensao (V3).
ifeq ($(UNAME_S),Darwin)
  TARGET_LIB := target/release/libdeckle_native.dylib
  INSTALLED  := lua/deckle_native.so
else ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
  TARGET_LIB := target/release/deckle_native.dll
  INSTALLED  := lua/deckle_native.dll
else
  TARGET_LIB := target/release/libdeckle_native.so
  INSTALLED  := lua/deckle_native.so
endif

.PHONY: native bench check-merman dump

# O binario antigo e removido ANTES do build: um binario velho no lugar faz o teste "passar"
# com `attempt to call a nil value`, que parece sucesso e nao e (aconteceu duas vezes na
# validacao). Se o build falhar, o alvo falha e nao sobra binario. `--locked` usa o
# Cargo.lock versionado, que e o que mantem o merman na versao pinada.
native:
	rm -f $(INSTALLED)
	$(CARGO) build --release --locked -p deckle-native
	test -f $(TARGET_LIB) || { echo "make native: $(TARGET_LIB) nao foi gerado" >&2; exit 1; }
	cp $(TARGET_LIB) $(INSTALLED)
	@echo "make native: instalado $(INSTALLED)"

bench:
	$(CARGO) test --release -p deckle-native -- --ignored --nocapture bench_flowchart

check-merman:
	./scripts/check-merman-version.sh

# Desenha um arquivo .mmd com o mesmo caminho do plugin (fallback incluido) e imprime a arte:
#   make dump FILE=examples/x.mmd [WIDTH=100] [ASCII=1] [COLOR=1]
# Com COLOR=1 o desenho vem em TrueColor e os escapes SGR saem escritos como `\e`.
dump:
	@test -n "$(FILE)" || { echo "uso: make dump FILE=caminho.mmd [WIDTH=100] [ASCII=1] [COLOR=1]" >&2; exit 1; }
	DECKLE_DUMP="$(abspath $(FILE))" DECKLE_DUMP_WIDTH="$(or $(WIDTH),100)" DECKLE_DUMP_ASCII="$(ASCII)" \
	  DECKLE_DUMP_COLOR="$(COLOR)" \
	  $(CARGO) test -q -p deckle-native -- --ignored --nocapture dump_file
