--- Render de `list`.
---
--- Cada item vira o marcador, um espaço e o conteúdo, com recuo suspenso: a segunda linha do
--- texto e todo filho (sublista, parágrafo extra, código) alinham com o começo do texto, não
--- com o marcador. O conteúdo é renderizado numa largura menor pelo tamanho do marcador.
---
--- O IR não distingue lista apertada de solta, então todas saem apertadas: itens sem linha em
--- branco entre eles. Sublista cola no texto do item; qualquer outro filho tem uma linha em
--- branco antes.

local inline = require("deckle.render.inline")
local util = require("deckle.render.util")

local M = {}

--- O glifo muda a cada nível de aninhamento (`ctx.list_level`), em ciclo.
local BULLETS = {
  unicode = { "•", "◦", "▪" },
  ascii = { "-", "*", "+" },
}

--- Caixa de item de tarefa: `[false]` desmarcada, `[true]` marcada.
local CHECKBOX = {
  unicode = { [false] = "☐", [true] = "☑" },
  ascii = { [false] = "[ ]", [true] = "[x]" },
}

---@param block deckle.Block
---@param ctx deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(block, ctx)
  local charset = ctx.charset == "unicode" and "unicode" or "ascii"
  local level = ctx.list_level or 0
  local items = block.items or {}

  local first = block.start or 1
  -- Números alinhados à direita pelo maior: ` 9.` e `10.`, não `9.` e `10.` tortos.
  local digits = #tostring(first + #items - 1)

  local lines, marks = {}, {}
  for index, item in ipairs(items) do
    local marker
    if block.ordered then
      local number = tostring(first + index - 1)
      marker = string.rep(" ", digits - #number) .. number .. "."
      if item.checked ~= nil then
        marker = marker .. " " .. CHECKBOX[charset][item.checked]
      end
    elseif item.checked ~= nil then
      marker = CHECKBOX[charset][item.checked]
    else
      local glyphs = BULLETS[charset]
      marker = glyphs[level % #glyphs + 1]
    end

    local consumed = util.width(marker) + 1
    local text_width = math.max(ctx.width - consumed, util.MIN_WIDTH)

    local item_lines, item_marks = {}, {}
    if item.spans and #item.spans > 0 then
      item_lines, item_marks = inline.layout(item.spans, text_width)
    end
    for _, child in ipairs(item.children or {}) do
      local child_lines, child_marks = ctx.block(child, consumed, { list_level = level + 1 })
      if #child_lines > 0 then
        if #item_lines > 0 and child.kind ~= "list" then
          item_lines[#item_lines + 1] = ""
        end
        util.append(item_lines, item_marks, child_lines, child_marks)
      end
    end
    if #item_lines == 0 then
      item_lines[1] = ""
    end

    util.prefix(item_lines, item_marks, marker .. " ", string.rep(" ", consumed))
    item_marks[#item_marks + 1] = { row = 0, col = 0, end_col = #marker, hl = "DeckleBullet" }
    util.append(lines, marks, item_lines, item_marks)
  end
  return lines, marks
end

return M
