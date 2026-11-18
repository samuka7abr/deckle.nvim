--- Render de `table` (fase 4): uma grade com bordas, colunas medidas por largura de display e
--- o alinhamento do delimitador.
---
--- ```
--- ┌──────────┬────────────┬───────────┐
--- │ L        │     C      │         R │
--- ├──────────┼────────────┼───────────┤
--- │ a        │     b      │         c │
--- │ 日本語   │     😀     │         ñ │
--- └──────────┴────────────┴───────────┘
--- ```
---
--- # Layout
---
--- * Cada coluna tem a largura da célula mais larga (cabeçalho incluído), medida com
---   `vim.api.nvim_strwidth` (nunca `#str`, e não `strdisplaywidth`, que depende da janela: ver
---   `display_width`), mais um espaço de cada lado. Emoji e CJK ocupam duas células, e todas as
---   linhas da tabela terminam na mesma coluna de display.
--- * O alinhamento vem de `block.align[i]` (`"left"`, `"center"`, `"right"` ou `nil`, que é
---   esquerda) e vale para o cabeçalho também. No centro, a célula que sobra por ser ímpar
---   fica à direita.
--- * O cabeçalho é separado do corpo por uma linha de grade. Tabela sem corpo não tem essa
---   linha: o cabeçalho fecha direto na borda de baixo.
--- * As bordas são `┌─┬┐│├┼┤└┴┘` em `unicode` e `+-|` em `ascii`. Se o terminal mede os
---   caracteres de caixa em duas células (`ambiwidth=double`, comum em locale CJK), as colunas
---   não alinhariam, então a tabela cai para as bordas ASCII, que têm sempre uma célula.
---
--- # Células
---
--- Uma célula é uma linha só: os spans inline passam por `deckle.render.inline` e mantêm o
--- highlight (negrito, código, link...), com as marcas deslocadas para depois do recuo do
--- alinhamento. Espaço em volta e quebra de linha viram um espaço só.
---
--- # Tabela mais larga que a janela
---
--- A tabela só ocupa o que precisa. Se passa de `ctx.width`, a coluna mais larga é truncada
--- com reticências (`…` em unicode, `...` em ascii) e o processo se repete até caber: na
--- prática as colunas mais largas são niveladas num mesmo teto. Quando o teto deixa sobra por
--- divisão inexata, ela vai para as colunas da esquerda. O corte é por cluster de grafemas,
--- então um caractere largo (CJK, emoji, sequência com ZWJ) nunca é partido ao meio. Não há
--- scroll horizontal nesta fase.
---
--- Uma coluna nunca encolhe abaixo da largura das reticências. Se mesmo assim não cabe (muitas
--- colunas para a janela), a tabela transborda `ctx.width`: a janela de preview não quebra
--- linha, então o excesso rola na horizontal, como o código.
---
--- # Linhas tortas
---
--- O número de colunas é `#header`, o que o delimitador também fixa. Linha com menos células é
--- completada com células vazias. Linha com **mais** células perde as extras, que não têm
--- coluna nem cabeçalho (é o que o GFM faz). `align` tem buracos: nunca se usa `#align`.
---
--- # Highlights
---
--- `DeckleTableBorder` cobre cada glifo de borda, e `DeckleTableHeader` cada célula do
--- cabeçalho (com o recuo). O do cabeçalho tem prioridade menor que a das marcas inline, para
--- o link ou o código dentro dele não perder a cor.

local inline = require("deckle.render.inline")
local util = require("deckle.render.util")

local M = {}

---@class deckle.TableBox
---@field h string       horizontal
---@field v string       vertical
---@field top string[]   esquerda, junção, direita
---@field mid string[]
---@field bot string[]
---@field ellipsis string

---@type table<string, deckle.TableBox>
local BOX = {
  unicode = {
    h = "─",
    v = "│",
    top = { "┌", "┬", "┐" },
    mid = { "├", "┼", "┤" },
    bot = { "└", "┴", "┘" },
    ellipsis = "…",
  },
  ascii = {
    h = "-",
    v = "|",
    top = { "+", "+", "+" },
    mid = { "+", "+", "+" },
    bot = { "+", "+", "+" },
    ellipsis = "...",
  },
}

--- Largura de display de `s`, a que a janela de preview vai desenhar.
---
--- Não é `util.width`: `strdisplaywidth` mede na janela atual e, se ela tem `wrap`, conta uma
--- célula a mais quando um caractere largo cai na última coluna (ele iria para a linha de
--- baixo). Uma célula de CJK mais larga que a janela atual sai então maior do que a janela
--- de preview, que não quebra linha, vai mostrar, e a linha da tabela ficaria curta.
--- `nvim_strwidth` é a mesma medida (emoji, `ambiwidth`, combinantes) sem depender da janela.
---@param s string
---@return integer
local function display_width(s)
  if not s:find("[\128-\255]") then
    return #s
  end
  return vim.api.nvim_strwidth(s)
end

--- Prioridade do highlight do cabeçalho: abaixo do padrão de um extmark (4096), onde ficam as
--- marcas inline, para que elas vençam quando o atributo conflita (a cor de um link).
local HEADER_PRIORITY = 4000

--- Espaços de cada lado do conteúdo de uma célula.
local PAD = 1

---@class deckle.TableCell
---@field text string
---@field marks { col: integer, end_col: integer, hl: string }[]  bytes dentro de `text`
---@field w integer  largura de display de `text`

---@type deckle.TableCell
local EMPTY = { text = "", marks = {}, w = 0 }

--- A célula numa linha só: o layout inline com largura infinita, e uma quebra forçada
--- (`<br>`) vira um espaço.
---@param spans deckle.Span[]
---@return deckle.TableCell
local function make_cell(spans)
  local lines, marks = inline.layout(spans, math.huge)
  local starts, pos = {}, 0
  for i, line in ipairs(lines) do
    starts[i] = pos
    pos = pos + #line + 1
  end
  local cell_marks = {}
  for _, mark in ipairs(marks) do
    local base = starts[mark.row + 1]
    cell_marks[#cell_marks + 1] =
      { col = base + mark.col, end_col = base + mark.end_col, hl = mark.hl }
  end
  local text = table.concat(lines, " ")
  return { text = text, marks = cell_marks, w = display_width(text) }
end

--- Corta a célula para caber em `width` células, com reticências no fim. Devolve a própria
--- célula se já cabe. Um estilo que atravessa o corte continua nas reticências.
---@param cell deckle.TableCell
---@param width integer  nunca menor que a largura das reticências
---@param ellipsis string
---@param ellipsis_w integer
---@return deckle.TableCell
local function truncate(cell, width, ellipsis, ellipsis_w)
  if cell.w <= width then
    return cell
  end
  local budget = width - ellipsis_w
  local head, bytes, used
  if not cell.text:find("[\128-\255]") then
    -- ASCII: um byte é uma célula, sem precisar partir um texto possivelmente enorme em clusters.
    head, bytes, used = cell.text:sub(1, budget), budget, budget
  else
    local kept = {}
    bytes, used = 0, 0
    for _, cluster in ipairs(util.clusters(cell.text)) do
      local cluster_w = display_width(cluster)
      if used + cluster_w > budget then
        break
      end
      kept[#kept + 1] = cluster
      bytes = bytes + #cluster
      used = used + cluster_w
    end
    head = table.concat(kept)
  end
  local marks = {}
  for _, mark in ipairs(cell.marks) do
    if mark.col < bytes then
      marks[#marks + 1] = {
        col = mark.col,
        end_col = mark.end_col > bytes and bytes + #ellipsis or mark.end_col,
        hl = mark.hl,
      }
    end
  end
  return { text = head .. ellipsis, marks = marks, w = used + ellipsis_w }
end

---@param list integer[]
---@return integer
local function sum(list)
  local total = 0
  for _, value in ipairs(list) do
    total = total + value
  end
  return total
end

--- Larguras de coluna que somam no máximo `avail`, truncando a mais larga até caber.
---
--- Truncar a coluna mais larga, uma célula por vez, até caber, termina com todas as colunas
--- largas niveladas num teto. Acha-se o teto direto, por busca binária, em vez de fazer um
--- passo por célula (uma célula de um megabyte não pode custar um milhão de voltas). As
--- colunas cortadas ficam no teto, e a sobra da divisão inexata vai para as da esquerda.
---
--- Se nem com todas as colunas no piso cabe, devolve o piso (a tabela transborda).
---@param natural integer[]  largura natural de cada coluna
---@param floors integer[]   menor largura que cada coluna aceita
---@param avail integer      células para o conteúdo, sem bordas nem recuos
---@return integer[]
local function fit(natural, floors, avail)
  if sum(natural) <= avail then
    return natural
  end

  ---@param level integer
  ---@return integer[]
  local function at(level)
    local widths = {}
    for i, w in ipairs(natural) do
      widths[i] = math.max(math.min(w, level), floors[i])
    end
    return widths
  end

  if sum(floors) >= avail then
    return floors
  end

  -- Invariante: `at(low)` cabe e `at(high)` não cabe.
  local low, high = 0, 0
  for _, w in ipairs(natural) do
    high = math.max(high, w)
  end
  while high - low > 1 do
    local mid = math.floor((low + high) / 2)
    if sum(at(mid)) <= avail then
      low = mid
    else
      high = mid
    end
  end

  local widths = at(low)
  local spare = avail - sum(widths)
  for i = 1, #widths do
    if spare == 0 then
      break
    end
    if natural[i] > low and widths[i] == low then
      widths[i] = widths[i] + 1
      spare = spare - 1
    end
  end
  return widths
end

--- O charset que a tabela realmente usa. `unicode` cai para `ascii` se algum caractere de
--- caixa não mede uma célula, o que desalinharia as colunas.
---@param charset string
---@return deckle.TableBox
local function resolve_box(charset)
  local box = BOX[charset] or BOX.ascii
  if box ~= BOX.ascii then
    local glyphs = { box.h, box.v }
    for _, part in ipairs({ box.top, box.mid, box.bot }) do
      vim.list_extend(glyphs, part)
    end
    if display_width(table.concat(glyphs)) ~= #glyphs then
      return BOX.ascii
    end
  end
  return box
end

---@param block deckle.Block
---@param ctx deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(block, ctx)
  local header = block.header or {}
  local body = block.rows or {}
  local align = block.align or {}

  local ncols = #header
  if ncols == 0 then
    -- Não sai do parser (o cabeçalho define a tabela), mas um IR montado à mão pode vir assim.
    for _, row in ipairs(body) do
      ncols = math.max(ncols, #row)
    end
  end
  if ncols == 0 then
    return {}, {}
  end

  ---@param cells deckle.Span[][]
  ---@return deckle.TableCell[]
  local function build_row(cells)
    local row = {}
    for i = 1, ncols do
      row[i] = cells[i] and make_cell(cells[i]) or EMPTY
    end
    return row
  end

  local has_header = #header > 0
  local grid = {}
  if has_header then
    grid[1] = build_row(header)
  end
  for _, cells in ipairs(body) do
    grid[#grid + 1] = build_row(cells)
  end

  local box = resolve_box(ctx.charset)
  local ellipsis_w = display_width(box.ellipsis)

  local natural, floors = {}, {}
  for i = 1, ncols do
    local widest = 0
    for _, row in ipairs(grid) do
      widest = math.max(widest, row[i].w)
    end
    natural[i] = widest
    floors[i] = math.min(widest, ellipsis_w)
  end
  -- Cada coluna gasta `PAD` de cada lado mais uma borda; falta ainda a borda final.
  local overhead = ncols * (2 * PAD + 1) + 1
  local widths = fit(natural, floors, ctx.width - overhead)

  local lines, marks = {}, {}

  ---@param glyphs string[]
  local function border(glyphs)
    local runs = {}
    for i = 1, ncols do
      runs[i] = string.rep(box.h, widths[i] + 2 * PAD)
    end
    local line = glyphs[1] .. table.concat(runs, glyphs[2]) .. glyphs[3]
    marks[#marks + 1] = { row = #lines, col = 0, end_col = #line, hl = "DeckleTableBorder" }
    lines[#lines + 1] = line
  end

  ---@param row deckle.TableCell[]
  ---@param is_header boolean
  local function render_row(row, is_header)
    local index = #lines
    local parts, bytes = {}, 0

    ---@param text string
    local function put(text)
      parts[#parts + 1] = text
      bytes = bytes + #text
    end

    local function bar()
      marks[#marks + 1] =
        { row = index, col = bytes, end_col = bytes + #box.v, hl = "DeckleTableBorder" }
      put(box.v)
    end

    for i = 1, ncols do
      bar()
      local cell = truncate(row[i], widths[i], box.ellipsis, ellipsis_w)
      local gap = widths[i] - cell.w
      local lead = 0
      if align[i] == "right" then
        lead = gap
      elseif align[i] == "center" then
        lead = math.floor(gap / 2)
      end

      local from = bytes
      put(string.rep(" ", PAD + lead))
      for _, mark in ipairs(cell.marks) do
        marks[#marks + 1] = {
          row = index,
          col = bytes + mark.col,
          end_col = bytes + mark.end_col,
          hl = mark.hl,
        }
      end
      put(cell.text)
      put(string.rep(" ", PAD + gap - lead))
      if is_header then
        marks[#marks + 1] = {
          row = index,
          col = from,
          end_col = bytes,
          hl = "DeckleTableHeader",
          priority = HEADER_PRIORITY,
        }
      end
    end
    bar()
    lines[#lines + 1] = table.concat(parts)
  end

  border(box.top)
  for i, row in ipairs(grid) do
    render_row(row, has_header and i == 1)
    if has_header and i == 1 and #grid > 1 then
      border(box.mid)
    end
  end
  border(box.bot)
  return lines, marks
end

return M
