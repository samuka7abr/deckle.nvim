--- Spans inline -> linhas quebradas por largura de display, com marcas.
---
--- É o miolo de `heading`, `paragraph` e do texto de cada item de lista. O caminho é
--- `flatten` (spans aninhados viram pedaços de texto com uma pilha de estilos), `tokenize`
--- (pedaços viram palavras e espaços, com as oportunidades de quebra) e `pack` (palavras
--- viram linhas). Largura é sempre `vim.fn.strdisplaywidth`, nunca `#str`.
---
--- Onde a linha pode quebrar:
---
--- * num espaço (o espaço some na quebra);
--- * entre um caractere largo (CJK, emoji) e o vizinho, com ou sem espaço, porque CJK não
---   separa palavras com espaço;
--- * no meio de uma palavra que sozinha é mais larga que a linha (uma URL comprida).
---
--- Um cluster (emoji com ZWJ, letra com acento combinante) nunca é partido.

local util = require("deckle.render.util")

local M = {}

---@alias deckle.Style string[] grupos de highlight acumulados dos spans que envolvem o texto

---@type deckle.Style
local NO_STYLE = {}

---@param style deckle.Style
---@param group string
---@return deckle.Style
local function push(style, group)
  local out = {}
  for i = 1, #style do
    out[i] = style[i]
  end
  out[#out + 1] = group
  return out
end

--- Pedaço de texto com estilo. `brk` marca a quebra forçada.
---@class deckle.Piece
---@field text string|nil
---@field style deckle.Style|nil
---@field brk boolean|nil

---@param spans deckle.Span[]
---@param style deckle.Style
---@param out deckle.Piece[]
local function flatten(spans, style, out)
  for _, span in ipairs(spans) do
    local kind = span.kind
    if kind == "text" then
      out[#out + 1] = { text = span.text, style = style }
    elseif kind == "code" then
      out[#out + 1] = { text = span.text, style = push(style, "DeckleCodeInline") }
    elseif kind == "strong" then
      flatten(span.children or {}, push(style, "DeckleStrong"), out)
    elseif kind == "emphasis" then
      flatten(span.children or {}, push(style, "DeckleEmphasis"), out)
    elseif kind == "link" then
      local inner = span.children or {}
      if #inner == 0 and (span.href or "") ~= "" then
        -- `[](url)` não tem texto: o destino é tudo que há para mostrar.
        inner = { { kind = "text", text = span.href } }
      end
      flatten(inner, push(style, "DeckleLink"), out)
    elseif kind == "image" then
      local alt = span.alt or ""
      out[#out + 1] = {
        text = alt ~= "" and ("[image: " .. alt .. "]") or "[image]",
        style = push(style, "DeckleImage"),
      }
    elseif kind == "break" then
      out[#out + 1] = { brk = true }
    elseif span.children then
      -- Contêiner que não conhecemos: o texto dele aparece, sem estilo próprio.
      flatten(span.children, style, out)
    end
  end
end

---@class deckle.Seg
---@field text string
---@field style deckle.Style

--- Uma palavra (ou um caractere largo): o que não quebra por dentro.
---@class deckle.Token
---@field segs deckle.Seg[]|nil
---@field w integer|nil
---@field sp boolean|nil          veio depois de espaço (senão, está colado no anterior)
---@field sp_style deckle.Style|nil  estilo do espaço que antecede
---@field brk boolean|nil         quebra forçada de linha

---@param pieces deckle.Piece[]
---@param width integer
---@return deckle.Token[]
local function tokenize(pieces, width)
  local tokens = {}
  local cur = nil -- palavra estreita em construção
  local pending = false
  local pending_style = NO_STYLE

  local function finish()
    if cur then
      tokens[#tokens + 1] = cur
      cur = nil
    end
  end

  ---@param text string
  ---@param style deckle.Style
  ---@param w integer
  local function add_seg(text, style, w)
    if not cur then
      cur = { segs = {}, w = 0, sp = pending, sp_style = pending_style }
      pending = false
    end
    local last = cur.segs[#cur.segs]
    if last and last.style == style then
      last.text = last.text .. text
    else
      cur.segs[#cur.segs + 1] = { text = text, style = style }
    end
    cur.w = cur.w + w
  end

  --- Texto sem espaço e sem caractere largo. Cabendo na linha, entra inteiro; senão, a
  --- palavra é mais larga que a linha e é partida em clusters.
  ---@param text string
  ---@param style deckle.Style
  ---@param w integer
  local function narrow(text, style, w)
    if (cur and cur.w or 0) + w <= width then
      add_seg(text, style, w)
      return
    end
    for _, cluster in ipairs(util.clusters(text)) do
      local cw = util.width(cluster)
      if cur and cur.w > 0 and cur.w + cw > width then
        finish()
      end
      add_seg(cluster, style, cw)
    end
  end

  ---@param cluster string
  ---@param style deckle.Style
  ---@param w integer
  local function wide(cluster, style, w)
    finish()
    tokens[#tokens + 1] = {
      segs = { { text = cluster, style = style } },
      w = w,
      sp = pending,
      sp_style = pending_style,
    }
    pending = false
  end

  ---@param run string sem espaço nenhum
  ---@param style deckle.Style
  local function word(run, style)
    if not run:find("[\128-\255]") then
      narrow(run, style, #run)
      return
    end
    local buf, buf_w = {}, 0
    for _, cluster in ipairs(util.clusters(run)) do
      local cw = util.width(cluster)
      if cw >= 2 then
        if #buf > 0 then
          narrow(table.concat(buf), style, buf_w)
          buf, buf_w = {}, 0
        end
        wide(cluster, style, cw)
      else
        buf[#buf + 1] = cluster
        buf_w = buf_w + cw
      end
    end
    if #buf > 0 then
      narrow(table.concat(buf), style, buf_w)
    end
  end

  for _, piece in ipairs(pieces) do
    if piece.brk then
      finish()
      tokens[#tokens + 1] = { brk = true }
      pending = false
    else
      -- Controle (tab, "\r", NUL) tem largura que depende do contexto e quebraria a conta:
      -- vira espaço, e espaço colapsa.
      local text = piece.text:gsub("%c", " ")
      local pos, n = 1, #text
      while pos <= n do
        local s, e = text:find("^%s+", pos)
        if s then
          finish()
          if not pending then
            pending = true
            pending_style = piece.style
          end
          pos = e + 1
        else
          local _, stop = text:find("^%S+", pos)
          word(text:sub(pos, stop), piece.style)
          pos = stop + 1
        end
      end
    end
  end
  finish()
  return tokens
end

---@param tokens deckle.Token[]
---@param width integer
---@return string[] lines, deckle.Mark[] marks
local function pack(tokens, width)
  local lines, marks = {}, {}
  local parts, bytes, line_w, row = {}, 0, 0, 0
  -- Última marca de cada grupo na linha atual: texto contíguo com o mesmo estilo (a palavra,
  -- o espaço e a palavra seguinte de um trecho em negrito) vira uma marca só.
  local open = {}

  local function flush()
    lines[#lines + 1] = table.concat(parts)
    parts, bytes, line_w, open = {}, 0, 0, {}
    row = row + 1
  end

  ---@param text string
  ---@param style deckle.Style
  local function emit(text, style)
    local col = bytes
    parts[#parts + 1] = text
    bytes = bytes + #text
    for _, hl in ipairs(style) do
      local mark = open[hl]
      if mark and mark.end_col == col then
        mark.end_col = bytes
      else
        mark = { row = row, col = col, end_col = bytes, hl = hl }
        marks[#marks + 1] = mark
        open[hl] = mark
      end
    end
  end

  for _, token in ipairs(tokens) do
    if token.brk then
      flush()
    else
      local space = (line_w > 0 and token.sp) and 1 or 0
      if line_w > 0 and line_w + space + token.w > width then
        flush()
        space = 0
      end
      if space == 1 then
        emit(" ", token.sp_style or NO_STYLE)
      end
      for _, seg in ipairs(token.segs) do
        emit(seg.text, seg.style)
      end
      line_w = line_w + space + token.w
    end
  end
  if #parts > 0 then
    flush()
  end
  if #lines == 0 then
    lines[1] = ""
  end
  return lines, marks
end

--- Quebra `spans` em linhas de no máximo `width` células.
---
--- Devolve sempre pelo menos uma linha (`""` para spans vazios). Marcas: `DeckleStrong`,
--- `DeckleEmphasis`, `DeckleCodeInline`, `DeckleLink` e `DeckleImage`, empilhadas quando os
--- spans aninham. Imagem vira `[image: alt]`: o texto alternativo é tudo que a camada 0 mostra.
---@param spans deckle.Span[]
---@param width integer
---@return string[] lines, deckle.Mark[] marks
function M.layout(spans, width)
  width = math.max(width or 1, 1)
  local pieces = {}
  flatten(spans or {}, NO_STYLE, pieces)
  return pack(tokenize(pieces, width), width)
end

return M
