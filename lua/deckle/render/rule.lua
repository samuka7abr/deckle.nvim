--- Render de `rule` (`---`): uma linha da largura inteira disponível.

local util = require("deckle.render.util")

local M = {}

local GLYPH = { unicode = "─", ascii = "-" }

---@param _ deckle.Block
---@param ctx deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(_, ctx)
  local glyph = GLYPH[ctx.charset] or GLYPH.ascii
  -- Dividir pela largura do glifo, não por 1: com `ambiwidth=double` o `─` ocupa 2 células.
  local line = string.rep(glyph, math.max(math.floor(ctx.width / util.width(glyph)), 1))
  return { line }, { { row = 0, col = 0, end_col = #line, hl = "DeckleRule" } }
end

return M
