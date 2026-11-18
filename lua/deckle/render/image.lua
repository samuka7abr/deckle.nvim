--- Imagem de verdade para o parágrafo que é só uma imagem (fase 9).
---
--- Não é um módulo de tipo de bloco (o IR não tem bloco `image`: a imagem é um span, e `parse`
--- não muda): é o gancho que `paragraph` consulta antes de quebrar o texto. Sem `ctx.images` (o
--- preview não tem protocolo gráfico) ou com uma imagem que o provedor recusa, devolve `nil` e o
--- parágrafo segue o caminho de sempre, o texto alternativo.
---
--- O bloco que sai tem `handle.rows` linhas de `handle.cols` células de placeholder (ver
--- `deckle.image.kitty`), cada linha com uma marca de `handle.hl`, o grupo que carrega o id da
--- imagem na cor. Para o mapa de sync é um bloco como outro qualquer.

local kitty = require("deckle.image.kitty")

local M = {}

--- A imagem de um parágrafo feito só dela (com espaço em volta, que o Markdown ignora). Qualquer
--- outra coisa junto (texto, link, código, quebra, uma segunda imagem) devolve `nil`.
---@param spans deckle.Span[]|nil
---@return deckle.Span|nil
local function sole_image(spans)
  local found = nil
  for _, span in ipairs(spans or {}) do
    if span.kind == "image" and not found then
      found = span
    elseif not (span.kind == "text" and not (span.text or ""):find("%S")) then
      return nil
    end
  end
  return found
end

---@param block deckle.Block  um `paragraph`
---@param ctx deckle.RenderCtx
---@return string[]|nil lines, deckle.Mark[]|nil marks
function M.render(block, ctx)
  local provider = ctx.images
  if not provider then
    return nil
  end
  local span = sole_image(block.spans)
  if not span or (span.src or "") == "" then
    return nil
  end
  local handle = provider.lookup(span.src, ctx.width)
  if not handle then
    return nil
  end

  local lines, marks = {}, {}
  for row = 0, handle.rows - 1 do
    local line = kitty.placeholder_row(row, handle.cols)
    lines[#lines + 1] = line
    marks[#marks + 1] = { row = row, col = 0, end_col = #line, hl = handle.hl }
  end
  return lines, marks
end

return M
