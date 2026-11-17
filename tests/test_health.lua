-- Testes de `:checkhealth deckle`.
--
-- ADR-0004 exige que o checkhealth diga em que camada o usuário está. Se isso quebrar,
-- degradação silenciosa vira bug reportado, então tem teste.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      -- O checkhealth lê `stdpath("data")/deckle/` (fase 8). Sem isto o resultado dependeria de
      -- o desenvolvedor ter ou não um binário instalado na própria máquina.
      child.lua([[vim.env.XDG_DATA_HOME = vim.fn.tempname()]])
    end,
    post_once = child.stop,
  },
})

--- Simula um binário já instalado no diretório de dados do filho.
---@param meta table|nil metadados (`install.json`); nil = só o arquivo, sem metadados
---@param with_binary boolean
local function seed_install(meta, with_binary)
  child.lua(
    [[
      local meta, with_binary = ...
      local dir = vim.fs.joinpath(vim.fn.stdpath("data"), "deckle")
      vim.fn.mkdir(dir, "p")
      if with_binary then
        local fd = assert(io.open(vim.fs.joinpath(dir, "deckle_native.so"), "wb"))
        fd:write("fake")
        fd:close()
      end
      if meta then
        local fd = assert(io.open(vim.fs.joinpath(dir, "install.json"), "w"))
        fd:write(vim.json.encode(meta))
        fd:close()
      end
    ]],
    { meta, with_binary }
  )
end

---@return string versão do plugin, que o instalador compara com a dos metadados
local function plugin_version()
  return child.lua_get([[require("deckle.version")]])
end

---@return string relatório inteiro como um texto só
local function report()
  child.cmd("checkhealth deckle")
  return table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

T["o relatório roda e é do deckle"] = function()
  eq(report():match("deckle") ~= nil, true)
end

T["informa a camada atual"] = function()
  eq(report():match("layer 0") ~= nil, true)
end

T["diz o que falta para subir de camada"] = function()
  eq(report():match("layer 1") ~= nil, true)
end

T["encontra os parsers que vêm do core"] = function()
  local text = report()
  eq(text:match("`markdown` parser found") ~= nil, true)
  eq(text:match("`markdown_inline` parser found") ~= nil, true)
end

T["num ambiente suportado não reporta erro nem warning"] = function()
  local text = report()
  eq(text:match("ERROR") ~= nil, false)
  eq(text:match("WARNING") ~= nil, false)
end

T["sem `setup()`, diz que está rodando nos defaults"] = function()
  local text = report()
  eq(text:match("was not called") ~= nil, true)
  eq(text:match("split=vsplit") ~= nil, true)
end

T["com `setup()`, ecoa a configuração efetiva"] = function()
  child.lua([[require("deckle").setup({ split = "tab", charset = "ascii", width = 90 })]])
  local text = report()
  eq(text:match("`setup%(%)` was called") ~= nil, true)
  eq(text:match("split=tab") ~= nil, true)
  eq(text:match("charset=ascii") ~= nil, true)
  eq(text:match("width=90") ~= nil, true)
end

T["sem width, mostra que usa a largura da janela"] = function()
  eq(report():match("width=window") ~= nil, true)
end

-- ---------------------------------------------------------------------------------------
-- Binário nativo (fase 8): de onde veio e onde está
-- ---------------------------------------------------------------------------------------

T["binário nativo"] = new_set()

--- Um `make native` na própria máquina deixa `lua/deckle_native.so` no plugin, que tem
--- precedência sobre o diretório de dados e muda a resposta. Os casos que dependem de o
--- binário estar ausente não rodam nesse checkout.
local function skip_with_dev_build()
  if vim.uv.fs_stat("lua/deckle_native.so") or vim.uv.fs_stat("lua/deckle_native.dll") then
    MiniTest.skip("há um `make native` neste checkout (lua/deckle_native.*)")
  end
end

T["binário nativo"]["ausente: diz o motivo, que a camada é 0 e como instalar"] = function()
  skip_with_dev_build()
  local text = report()
  eq(text:match("Native binary") ~= nil, true)
  eq(text:find("missing — not installed", 1, true) ~= nil, true)
  eq(text:match(":Deckle install") ~= nil, true)
  eq(text:match("make native") ~= nil, true)
  eq(text:match("layer 0") ~= nil, true)
end

T["binário nativo"]["ausente e sem tentativa de instalação não é warning nem erro"] = function()
  skip_with_dev_build()
  local text = report()
  eq(text:match("WARNING") ~= nil, false)
  eq(text:match("ERROR") ~= nil, false)
end

T["binário nativo"]["de release: diz a origem, a versão, o alvo e o caminho"] = function()
  skip_with_dev_build()
  seed_install({
    origin = "release",
    version = plugin_version(),
    target = "x86_64-unknown-linux-gnu",
    source = "https://example.invalid/asset",
  }, true)

  local text = report()
  eq(text:match("installed from a release") ~= nil, true)
  eq(text:match("v" .. vim.pesc(plugin_version())) ~= nil, true)
  eq(text:match("x86_64%-unknown%-linux%-gnu") ~= nil, true)
  eq(text:match("deckle_native%.so") ~= nil, true)
  eq(text:match("WARNING") ~= nil, false)
end

T["binário nativo"]["de build local: diz que foi compilado"] = function()
  skip_with_dev_build()
  seed_install({
    origin = "build",
    version = plugin_version(),
    target = "x86_64-unknown-linux-gnu",
    source = "cargo build --release",
  }, true)

  local text = report()
  eq(text:match("built locally") ~= nil, true)
  eq(text:match("deckle_native%.so") ~= nil, true)
end

T["binário nativo"]["de outra versão do plugin conta como ausente e diz as duas versões"] = function()
  skip_with_dev_build()
  seed_install({ origin = "release", version = "0.0.1", target = "x" }, true)

  local text = report()
  eq(text:match("missing") ~= nil, true)
  eq(text:match("v0%.0%.1") ~= nil, true)
  eq(text:match("v" .. vim.pesc(plugin_version())) ~= nil, true)
end

T["binário nativo"]["depois de uma instalação que falhou, mostra o motivo como warning"] = function()
  skip_with_dev_build()
  seed_install({
    origin = "missing",
    version = plugin_version(),
    last_error = { message = "checksum mismatch for the asset", at = 0 },
  }, false)

  local text = report()
  eq(text:match("WARNING") ~= nil, true)
  eq(text:match("last install attempt failed") ~= nil, true)
  eq(text:match("checksum mismatch for the asset") ~= nil, true)
  -- A camada 0 segue valendo: é aviso, não erro.
  eq(text:match("ERROR") ~= nil, false)
  eq(text:match("layer 0") ~= nil, true)
end

T["binário nativo"]["`native.path` configurado aparece no relatório"] = function()
  child.lua([[require("deckle").setup({ native = { path = "/opt/custom/deckle_native.so" } })]])
  eq(report():match("/opt/custom/deckle_native%.so") ~= nil, true)
end

T["binário nativo"]["`native.enabled = false` aparece no relatório"] = function()
  child.lua([[require("deckle").setup({ native = { enabled = false } })]])
  eq(report():match("native%.enabled` is false") ~= nil, true)
end

T["binário nativo"]["um erro dentro do instalador não derruba o checkhealth"] = function()
  child.lua([[
    package.loaded["deckle.install"] = {
      info = function()
        error("boom")
      end,
    }
  ]])
  local text = report()
  eq(text:match("could not inspect the installed binary") ~= nil, true)
  eq(text:match("boom") ~= nil, true)
end

return T
