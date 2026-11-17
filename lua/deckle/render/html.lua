--- Render de `html`: as linhas cruas do bloco, em cor de comentário.
---
--- Não há o que renderizar de HTML num buffer de texto, e interpretá-lo está fora do escopo
--- do projeto. O bloco aparece como no fonte para não sumir conteúdo em silêncio.

local M = {}

---@param block deckle.Block
---@param _ deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(block, _)
  local lines, marks = {}, {}
  for row, line in ipairs(block.lines or {}) do
    lines[row] = line
    if line ~= "" then
      marks[#marks + 1] = { row = row - 1, col = 0, end_col = #line, hl = "DeckleHtml" }
    end
  end
  return lines, marks
end

return M
