--- Render de `code`: **fallback da fase 2**.
---
--- Só emite as linhas cruas do bloco, sem moldura, sem wrap (código não quebra: linha mais
--- larga que a janela transborda, e a janela de preview não tem `wrap`) e sem highlight de
--- linguagem. A fase 5 substitui este módulo pela moldura e pelo highlight via treesitter,
--- mantendo a assinatura `render(block, ctx) -> lines, marks`.

local M = {}

---@param block deckle.Block
---@param _ deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(block, _)
  local lines, marks = {}, {}
  for row, line in ipairs(block.lines or {}) do
    lines[row] = line
    if line ~= "" then
      marks[#marks + 1] = { row = row - 1, col = 0, end_col = #line, hl = "DeckleCode" }
    end
  end
  return lines, marks
end

return M
