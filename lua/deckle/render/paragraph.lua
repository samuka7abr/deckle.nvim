--- Render de `paragraph`: o texto quebrado na largura, com as marcas dos spans.

local image = require("deckle.render.image")
local inline = require("deckle.render.inline")

local M = {}

---@param block deckle.Block
---@param ctx deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(block, ctx)
  -- Um parágrafo que é só uma imagem local vira imagem, onde há protocolo gráfico (fase 9).
  local lines, marks = image.render(block, ctx)
  if lines then
    return lines, marks or {}
  end
  return inline.layout(block.spans or {}, ctx.width)
end

return M
