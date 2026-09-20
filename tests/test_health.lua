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
    end,
    post_once = child.stop,
  },
})

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

return T
