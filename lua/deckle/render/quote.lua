--- Render de `quote`: os filhos renderizados numa largura menor, com uma borda à esquerda
--- em toda linha (inclusive nas em branco entre os filhos, para a barra ser contínua).

local util = require("deckle.render.util")

local M = {}

local BORDER = { unicode = "│", ascii = "|" }

---@param block deckle.Block
---@param ctx deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(block, ctx)
  local border = BORDER[ctx.charset] or BORDER.ascii
  local consumed = util.width(border) + 1

  local lines, marks = {}, {}
  for _, child in ipairs(block.children or {}) do
    local child_lines, child_marks = ctx.block(child, consumed)
    if #child_lines > 0 then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      util.append(lines, marks, child_lines, child_marks)
    end
  end
  if #lines == 0 then
    -- Quote vazio: só a borda, para o bloco ocupar a linha em que está no fonte.
    lines[1] = ""
  end

  local prefix = border .. " "
  util.prefix(lines, marks, prefix, prefix)
  for row = 1, #lines do
    marks[#marks + 1] = { row = row - 1, col = 0, end_col = #border, hl = "DeckleQuote" }
  end
  return lines, marks
end

return M
