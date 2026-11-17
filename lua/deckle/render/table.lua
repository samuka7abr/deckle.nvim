--- Render de `table`: **fallback da fase 2**.
---
--- Devolve a tabela como texto cru de Markdown (`| a | b |`), sem alinhar colunas, sem
--- bordas e sem respeitar a largura da janela. A fase 4 substitui este módulo pela tabela
--- com largura de display, alinhamento e bordas, mantendo a assinatura
--- `render(block, ctx) -> lines, marks`.

local M = {}

---@param cell deckle.Span[]
---@return string
local function cell_text(cell)
  local text = require("deckle.parse").plain_text(cell)
  -- Uma célula é uma linha só, e `|` dentro dela é escapado, como no fonte.
  return (text:gsub("\n", " "):gsub("|", "\\|"))
end

---@param cells deckle.Span[][]
---@return string
local function row_text(cells)
  local parts = {}
  for i, cell in ipairs(cells) do
    parts[i] = cell_text(cell)
  end
  return "| " .. table.concat(parts, " | ") .. " |"
end

---@param block deckle.Block
---@param _ deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(block, _)
  local header = block.header or {}
  local rows = block.rows or {}

  local columns = #header
  for _, row in ipairs(rows) do
    columns = math.max(columns, #row)
  end

  local lines = {}
  if #header > 0 then
    lines[#lines + 1] = row_text(header)
  end
  if columns > 0 then
    local delimiter = {}
    for i = 1, columns do
      delimiter[i] = "---"
    end
    lines[#lines + 1] = "| " .. table.concat(delimiter, " | ") .. " |"
  end
  for _, row in ipairs(rows) do
    lines[#lines + 1] = row_text(row)
  end
  return lines, {}
end

return M
