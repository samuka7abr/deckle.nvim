-- Testes de `deckle` (init) e de `plugin/deckle.lua`.
--
-- Roda em Neovim filho de propósito: o gate 3 da fase 0 é sobre o que está em
-- `package.loaded`, e no processo do runner o módulo já foi carregado por outro teste.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
    end,
    post_once = child.stop,
  },
})

--- Troca o `vim.notify` do filho por um coletor. O despacho avisa por notify em vez de
--- lançar, então é assim que se observa o que ele fez.
local function capture_notifications()
  child.lua([[
    _G.captured = {}
    vim.notify = function(msg, level)
      table.insert(_G.captured, { msg = msg, level = level })
    end
  ]])
end

T["carregamento preguiçoso"] = new_set()

T["carregamento preguiçoso"]["`plugin/` registra `:Deckle` sem carregar o módulo"] = function()
  eq(child.fn.exists(":Deckle"), 2)
  eq(child.lua_get([[package.loaded["deckle"] ~= nil]]), false)
end

T["carregamento preguiçoso"]["`require('deckle')` não puxa submódulo"] = function()
  child.lua([[require("deckle")]])
  eq(child.lua_get([[package.loaded["deckle.config"] ~= nil]]), false)
  eq(child.lua_get([[package.loaded["deckle.health"] ~= nil]]), false)
end

T["carregamento preguiçoso"]["é `setup()` que carrega a config"] = function()
  child.lua([[require("deckle").setup()]])
  eq(child.lua_get([[package.loaded["deckle.config"] ~= nil]]), true)
end

T["completion"] = new_set()

T["completion"]["lista todos os subcomandos, na ordem"] = function()
  eq(
    child.lua_get([[require("deckle").complete("", "Deckle ")]]),
    { "open", "close", "toggle", "refresh", "health" }
  )
end

T["completion"]["filtra por prefixo"] = function()
  eq(child.lua_get([[require("deckle").complete("c", "Deckle c")]]), { "close" })
  eq(child.lua_get([[require("deckle").complete("h", "Deckle h")]]), { "health" })
end

T["completion"]["não sugere nada depois do subcomando escolhido"] = function()
  eq(child.lua_get([[require("deckle").complete("", "Deckle open ")]]), {})
end

T["completion"]["prefixo que não casa devolve lista vazia"] = function()
  eq(child.lua_get([[require("deckle").complete("zz", "Deckle zz")]]), {})
end

T["despacho"] = new_set()

T["despacho"]["subcomando desconhecido avisa e não lança"] = function()
  capture_notifications()
  child.cmd("Deckle bogus")
  eq(child.lua_get([[#_G.captured]]), 1)
  eq(child.lua_get([[_G.captured[1].msg:match("unknown subcommand") ~= nil]]), true)
  eq(child.lua_get([[_G.captured[1].level == vim.log.levels.ERROR]]), true)
end

T["despacho"]["sem argumento equivale a `toggle`"] = function()
  capture_notifications()
  child.cmd("Deckle")
  eq(child.lua_get([[_G.captured[1].msg:match("`toggle`") ~= nil]]), true)
end

T["despacho"]["os subcomandos de render avisam que ainda não existem"] = function()
  capture_notifications()
  for _, name in ipairs({ "open", "close", "toggle", "refresh" }) do
    child.cmd("Deckle " .. name)
  end
  eq(child.lua_get([[#_G.captured]]), 4)
  eq(child.lua_get([[_G.captured[1].msg:match("not wired yet") ~= nil]]), true)
  eq(child.lua_get([[_G.captured[1].level == vim.log.levels.WARN]]), true)
end

T["despacho"]["`health` abre o checkhealth"] = function()
  child.cmd("Deckle health")
  eq(child.lua_get([[vim.bo.filetype]]), "checkhealth")
end

T["despacho"]["`subcommands()` devolve cópia, não a lista viva"] = function()
  child.lua([==[
    local first = require("deckle").subcommands()
    first[1] = "mutado"
  ]==])
  eq(child.lua_get([==[require("deckle").subcommands()[1]]==]), "open")
end

return T
