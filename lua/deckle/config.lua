--- Defaults e validação da configuração do deckle.
---
--- Este módulo não encosta em buffer, janela nem autocmd. Ele só guarda a tabela de
--- configuração efetiva e garante que ela é válida. Carregar `deckle` não carrega este
--- módulo; `setup()` é que carrega.

local M = {}

--- Configuração de fábrica.
---
--- `width = nil` não aparece aqui de propósito: em Lua uma chave com valor nil não existe,
--- e nil já é o valor que significa "usar a largura da janela".
---@type table
local defaults = {
  split = "vsplit", -- "vsplit" | "split" | "tab"
  width = nil, -- nil = largura da janela
  charset = "auto", -- "auto" | "unicode" | "ascii"
  sync = "cursor", -- "cursor" | "off"
  debounce_ms = 120,
  native = { enabled = true, path = nil },
  mermaid = { max_src_lines = 200 },
}

--- Chaves aceitas em cada nível. Serve para pegar typo em opção, que de outro modo é
--- silenciosamente ignorado e vira bug reportado como "não funciona".
local known_keys = {
  [""] = { "split", "width", "charset", "sync", "debounce_ms", "native", "mermaid" },
  native = { "enabled", "path" },
  mermaid = { "max_src_lines" },
}

--- Configuração efetiva. Antes de `setup()`, é uma cópia dos defaults.
---@type table
M.options = vim.deepcopy(defaults)

--- Verdadeiro depois que `setup()` roda pelo menos uma vez. O checkhealth usa isso para
--- diferenciar "configurado pelo usuário" de "rodando no default".
---@type boolean
M.configured = false

---@return table cópia dos defaults, para teste e para documentação
function M.defaults()
  return vim.deepcopy(defaults)
end

--- Tira o `arquivo.lua:123: ` que o `error()` de dentro do `vim.validate` cola na frente.
--- O usuário precisa ler o que está errado na config dele, não o path do nosso fonte.
---@param msg any
---@return string
local function strip_position(msg)
  return (tostring(msg):gsub("^.-:%d+: ", ""))
end

--- Erro de configuração com prefixo do plugin e sem o rastro de `vim.validate`.
---@param msg string
local function fail(msg)
  error("deckle: " .. strip_position(msg), 0)
end

---@param value any
---@param allowed string[]
---@return boolean
local function one_of(value, allowed)
  for _, candidate in ipairs(allowed) do
    if value == candidate then
      return true
    end
  end
  return false
end

---@param allowed string[]
---@return function, string
local function enum(allowed)
  return function(value)
    return type(value) == "string" and one_of(value, allowed)
  end,
    'one of "' .. table.concat(allowed, '", "') .. '"'
end

---@param value any
---@return boolean
local function positive_int(value)
  return type(value) == "number" and value > 0 and value == math.floor(value)
end

--- Rejeita chave desconhecida antes de validar tipo, senão um typo em `native` passa batido.
---@param tbl table
---@param scope string chave vazia = nível de cima
local function reject_unknown(tbl, scope)
  local allowed = known_keys[scope]
  local lookup = {}
  for _, key in ipairs(allowed) do
    lookup[key] = true
  end
  for key in pairs(tbl) do
    if not lookup[key] then
      local where = scope == "" and "option" or ("option in `" .. scope .. "`")
      fail(
        string.format(
          "unknown %s `%s` (valid: %s)",
          where,
          tostring(key),
          table.concat(allowed, ", ")
        )
      )
    end
  end
end

--- Valida uma tabela de opções já mesclada com os defaults.
---
--- Lança erro com mensagem legível na primeira violação. Usa a assinatura nova de
--- `vim.validate` (Neovim 0.11), não a forma de tabela, que está depreciada.
---@param opts table
function M.validate(opts)
  vim.validate("opts", opts, "table")

  vim.validate("split", opts.split, enum({ "vsplit", "split", "tab" }))
  vim.validate("width", opts.width, positive_int, true, "a positive integer or nil")
  vim.validate("charset", opts.charset, enum({ "auto", "unicode", "ascii" }))
  vim.validate("sync", opts.sync, enum({ "cursor", "off" }))
  vim.validate("debounce_ms", opts.debounce_ms, function(value)
    return type(value) == "number" and value >= 0
  end, "a number >= 0")

  vim.validate("native", opts.native, "table")
  vim.validate("native.enabled", opts.native.enabled, "boolean")
  vim.validate("native.path", opts.native.path, "string", true)

  vim.validate("mermaid", opts.mermaid, "table")
  vim.validate(
    "mermaid.max_src_lines",
    opts.mermaid.max_src_lines,
    positive_int,
    false,
    "a positive integer"
  )
end

--- Mescla `opts` nos defaults, valida e guarda o resultado em `M.options`.
---
--- Em caso de erro, `M.options` não muda: configuração inválida deixa o plugin no estado
--- anterior em vez de meio configurado.
---@param opts table|nil
---@return table configuração efetiva
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    fail("setup() expects a table, got " .. type(opts))
  end

  reject_unknown(opts, "")
  if type(opts.native) == "table" then
    reject_unknown(opts.native, "native")
  end
  if type(opts.mermaid) == "table" then
    reject_unknown(opts.mermaid, "mermaid")
  end

  local merged = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

  local ok, err = pcall(M.validate, merged)
  if not ok then
    fail(err)
  end

  M.options = merged
  M.configured = true
  return M.options
end

return M
