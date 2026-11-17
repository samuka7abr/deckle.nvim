--- Render de `heading`.
---
--- O texto não leva `#`: o nível aparece na cor (`DeckleH1` a `DeckleH6`) e, em H1 e H2, num
--- sublinhado do tamanho da linha mais larga (`═` e `─`, ou `=` e `-` em ASCII). Sem isso os
--- seis níveis ficariam idênticos num esquema de cores que linke todos ao mesmo grupo.

local inline = require("deckle.render.inline")
local util = require("deckle.render.util")

local M = {}

local UNDERLINE = {
  unicode = { "═", "─" },
  ascii = { "=", "-" },
}

---@param block deckle.Block
---@param ctx deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(block, ctx)
  local level = math.min(math.max(block.level or 1, 1), 6)
  local group = "DeckleH" .. level
  local lines, marks = inline.layout(block.spans or {}, ctx.width)

  local widest = 0
  for row, line in ipairs(lines) do
    if line ~= "" then
      marks[#marks + 1] = { row = row - 1, col = 0, end_col = #line, hl = group }
    end
    widest = math.max(widest, util.width(line))
  end

  if level <= 2 and widest > 0 then
    local glyphs = UNDERLINE[ctx.charset] or UNDERLINE.ascii
    local glyph = glyphs[level]
    local underline = string.rep(glyph, math.max(math.floor(widest / util.width(glyph)), 1))
    lines[#lines + 1] = underline
    marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #underline, hl = group }
  end
  return lines, marks
end

return M
