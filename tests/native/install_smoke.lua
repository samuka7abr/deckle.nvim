-- Smoke test do artefato de release, de ponta a ponta: o instalador de verdade baixa o
-- binário de um diretório local (`file://`), confere o SHA-256, instala, e o módulo é
-- carregado pelo caminho que `info()` devolve e passa pela mesma bateria de
-- `native_headless.lua` (incluindo "erro em Rust não derruba o Neovim").
--
-- Quem roda é o `release.yml`, em cada runner nativo, antes de publicar. É a única prova
-- que o projeto tem de que o `.dylib` do macOS (flags `-undefined dynamic_lookup`) e a `.dll`
-- do Windows (import de `lua51.dll`) carregam num Neovim de verdade. Não roda na suíte
-- normal: precisa de um artefato já compilado.
--
--   nvim --headless -u NONE --cmd "set rtp^=<raiz do repo>" \
--        -l tests/native/install_smoke.lua <diretório com os deckle_native-*>
--
-- Sai com 0 se tudo passou e com 1 se algo falhou. Exit 134 é o nvim abortando: quem avalia
-- isso é o shell que chama.

local dist = arg and arg[1]
if not dist or dist == "" then
  print("uso: install_smoke.lua <diretório com os artefatos de release>")
  os.exit(2)
end

local function fail(msg)
  print("FAIL " .. msg)
  os.exit(1)
end

local function ok(msg)
  print("ok   " .. msg)
end

dist = dist:gsub("\\", "/")
-- `file:///D:/a/...` no Windows; `file:///tmp/...` no resto.
local base_url = "file://" .. (dist:match("^%a:") and "/" or "") .. dist

local install = require("deckle.install")
local install_dir = vim.fn.tempname()

local result
install.install({
  dir = install_dir,
  base_url = base_url,
  silent = true,
  -- Cair para o cargo aqui esconderia um artefato quebrado atrás de uma build local.
  build = function(_, cb)
    cb("the smoke test must not fall back to cargo")
  end,
}, function(r)
  result = r
end)
vim.wait(120000, function()
  return result ~= nil
end, 50)

if not result then
  fail("install() nunca chamou o callback")
end
if not result.ok then
  fail(("install falhou (%s): %s"):format(tostring(result.stage), tostring(result.error)))
end
ok("install do artefato pelo instalador (checksum conferido)")

local info = install.info({ dir = install_dir })
if info.origin ~= "release" then
  fail("info().origin deveria ser 'release', veio " .. tostring(info.origin))
end
ok(("info(): origin=%s target=%s path=%s"):format(info.origin, info.target, info.path))

-- É o caminho que a fase 7 vai seguir: `package.loadlib` no `info().path`.
local loader, load_err = package.loadlib(info.path, "luaopen_deckle_native")
if not loader then
  fail("package.loadlib falhou: " .. tostring(load_err))
end
ok("package.loadlib carregou o módulo")

package.preload["deckle_native"] = loader
dofile("tests/native/native_headless.lua")
