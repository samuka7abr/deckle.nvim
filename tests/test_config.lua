-- Testes de `deckle.config`: defaults, merge e validação.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local expect_error = MiniTest.expect.error

--- `config.options` é estado de módulo. Sem recarregar, um caso herda a configuração que
--- o caso anterior deixou e os testes passam a depender da ordem.
---@return table
local function fresh()
  package.loaded["deckle"] = nil
  package.loaded["deckle.config"] = nil
  return require("deckle.config")
end

local T = new_set()

T["defaults"] = new_set()

T["defaults"]["são os valores do roadmap"] = function()
  local d = fresh().defaults()
  eq(d.split, "vsplit")
  eq(d.width, nil)
  eq(d.charset, "auto")
  eq(d.sync, "cursor")
  eq(d.debounce_ms, 120)
  eq(d.native, { enabled = true })
  eq(d.mermaid, { max_src_lines = 200 })
end

T["defaults"]["`defaults()` devolve cópia, não a tabela viva"] = function()
  local config = fresh()
  local d = config.defaults()
  d.split = "tab"
  eq(config.defaults().split, "vsplit")
end

T["defaults"]["valem mesmo sem `setup()`"] = function()
  local config = fresh()
  eq(config.configured, false)
  eq(config.options.split, "vsplit")
end

T["setup"] = new_set()

T["setup"]["sem argumento aplica os defaults"] = function()
  local config = fresh()
  eq(config.setup().split, "vsplit")
  eq(config.configured, true)
end

T["setup"]["mescla fundo sem derrubar chave irmã"] = function()
  local opts = fresh().setup({ native = { enabled = false } })
  eq(opts.native.enabled, false)
  eq(opts.mermaid.max_src_lines, 200)
  eq(opts.split, "vsplit")
end

T["setup"]["chamar duas vezes substitui a configuração"] = function()
  local config = fresh()
  config.setup({ split = "tab" })
  config.setup({ split = "split" })
  eq(config.options.split, "split")
end

T["setup"]["não deixa o usuário mutar os defaults por referência"] = function()
  local config = fresh()
  config.setup({}).split = "tab"
  eq(config.defaults().split, "vsplit")
end

T["validação"] = new_set()

T["validação"]["recusa valor fora do enum"] = function()
  local config = fresh()
  expect_error(function()
    config.setup({ split = "floating" })
  end, "deckle: split: expected one of")
end

T["validação"]["recusa charset fora do enum"] = function()
  local config = fresh()
  expect_error(function()
    config.setup({ charset = "utf8" })
  end, "deckle: charset: expected one of")
end

T["validação"]["recusa sync fora do enum"] = function()
  local config = fresh()
  expect_error(function()
    config.setup({ sync = "scroll" })
  end, "deckle: sync: expected one of")
end

T["validação"]["recusa chave desconhecida no topo"] = function()
  local config = fresh()
  expect_error(function()
    config.setup({ splitt = "vsplit" })
  end, "unknown option `splitt`")
end

T["validação"]["recusa chave desconhecida aninhada"] = function()
  local config = fresh()
  expect_error(function()
    config.setup({ native = { enable = true } })
  end, "unknown option in `native`")
end

T["validação"]["recusa width zero e negativo"] = function()
  local config = fresh()
  expect_error(function()
    config.setup({ width = 0 })
  end, "width: expected a positive integer")
  expect_error(function()
    config.setup({ width = -10 })
  end, "width: expected a positive integer")
end

T["validação"]["aceita width nil, que significa largura da janela"] = function()
  eq(fresh().setup({ width = nil }).width, nil)
end

T["validação"]["recusa debounce negativo mas aceita zero"] = function()
  local config = fresh()
  expect_error(function()
    config.setup({ debounce_ms = -1 })
  end, "debounce_ms: expected a number >= 0")
  eq(fresh().setup({ debounce_ms = 0 }).debounce_ms, 0)
end

T["validação"]["recusa max_src_lines não-positivo"] = function()
  local config = fresh()
  expect_error(function()
    config.setup({ mermaid = { max_src_lines = 0 } })
  end, "mermaid.max_src_lines: expected a positive integer")
end

T["validação"]["recusa argumento que não é tabela"] = function()
  local config = fresh()
  expect_error(function()
    config.setup("vsplit")
  end, "setup%(%) expects a table")
end

T["validação"]["a mensagem não vaza o path do nosso fonte"] = function()
  local config = fresh()
  local ok, err = pcall(config.setup, { split = "floating" })
  eq(ok, false)
  eq(tostring(err):match("config%.lua") ~= nil, false)
  eq(vim.startswith(tostring(err), "deckle: "), true)
end

T["validação"]["config inválida deixa a anterior intacta"] = function()
  local config = fresh()
  config.setup({ split = "tab" })
  pcall(config.setup, { split = "floating" })
  eq(config.options.split, "tab")
end

return T
