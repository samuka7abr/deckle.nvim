--- Render de `paragraph`: o texto quebrado na largura, com as marcas dos spans.

local inline = require("deckle.render.inline")

local M = {}

---@param block deckle.Block
---@param ctx deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(block, ctx)
  return inline.layout(block.spans or {}, ctx.width)
end

return M
