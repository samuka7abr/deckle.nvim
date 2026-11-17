--- Ponto de entrada do deckle.
---
--- Carregar este módulo é de propósito barato: ele não dá `require` em nada. Só `setup()`
--- e o despacho de um subcomando é que puxam `deckle.config` e o resto. Isso é o gate de
--- saída 3 da fase 0, e tem teste que verifica.

local M = {}

--- Ordem importa: é a ordem que aparece na completion.
---@type string[]
local subcommands = { "open", "close", "toggle", "refresh", "health" }

---@param msg string
---@param level integer|nil
local function notify(msg, level)
  vim.notify("deckle: " .. msg, level or vim.log.levels.INFO)
end

--- `open`, `close`, `toggle` e `refresh` são do `deckle.preview`, carregado só quando o
--- subcomando roda. Atuam sobre o buffer atual, ou sobre o fonte dele se o foco estiver no
--- preview.
---@type table<string, fun(args: string[])>
local handlers = {
  open = function()
    require("deckle.preview").open()
  end,
  close = function()
    require("deckle.preview").close()
  end,
  toggle = function()
    require("deckle.preview").toggle()
  end,
  refresh = function()
    require("deckle.preview").refresh()
  end,
  health = function()
    vim.cmd("checkhealth deckle")
  end,
}

--- Aplica a configuração do usuário. Chamar com `nil` é válido e equivale aos defaults.
---
--- Configuração inválida lança erro com mensagem legível e deixa a configuração anterior
--- intacta. Chamar duas vezes é permitido: a segunda chamada substitui a primeira.
---@param opts table|nil
---@return table configuração efetiva
function M.setup(opts)
  return require("deckle.config").setup(opts)
end

--- Configuração efetiva, já mesclada com os defaults.
---@return table
function M.config()
  return require("deckle.config").options
end

---@return string[] cópia da lista de subcomandos
function M.subcommands()
  return vim.deepcopy(subcommands)
end

--- Despacho de `:Deckle [subcomando]`. Sem argumento equivale a `toggle`.
---@param args string[]|nil
function M.dispatch(args)
  args = args or {}
  local name = args[1] or "toggle"

  local handler = handlers[name]
  if not handler then
    notify(
      string.format("unknown subcommand `%s` (valid: %s)", name, table.concat(subcommands, ", ")),
      vim.log.levels.ERROR
    )
    return
  end

  handler({ unpack(args, 2) })
end

--- Completion de `:Deckle`. Só completa o primeiro argumento: nenhum subcomando aceita
--- argumento próprio nesta fase.
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local typed = vim.split(vim.trim(cmdline or ""), "%s+")
  -- `typed[1]` é o próprio `:Deckle`. Mais de um argumento já digitado e fechado por
  -- espaço significa que o subcomando já foi escolhido.
  if #typed > 2 or (#typed == 2 and arglead == "") then
    return {}
  end

  return vim.tbl_filter(function(name)
    return vim.startswith(name, arglead or "")
  end, vim.deepcopy(subcommands))
end

return M
