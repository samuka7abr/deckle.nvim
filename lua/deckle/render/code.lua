--- Render de `code` (fase 5): moldura e highlight por linguagem.
---
--- O bloco vira uma caixa, com o nome da linguagem na borda de cima quando o info string
--- tem um, e o texto colorido pelo parser treesitter da linguagem. O buffer de preview não tem
--- `filetype=markdown`, então a injeção de linguagem do treesitter não acontece sozinha: o
--- highlight é refeito aqui, com `vim.treesitter.get_string_parser` e a query `highlights`,
--- e sai como marcas comuns (`deckle.Mark`), que o `preview.lua` vira extmarks.
---
--- ```
--- ╭─ lua ───────────────╮
--- │ local x = "ñandú"   │
--- │ return x            │
--- ╰─────────────────────╯
--- nota opcional, uma linha
--- ```
---
--- # Largura
---
--- Código não quebra linha: a janela de preview não tem `wrap`, e o que passa da largura rola
--- na horizontal. A caixa tem `ctx.width` células, ou, se o código mais largo (já com os tabs
--- expandidos) não couber, o que ele precisar: todas as linhas da caixa ficam com a mesma
--- largura, e a borda direita fica no fim do código em vez de cortar no meio dele. O rótulo
--- nunca alarga a caixa; se for comprido demais, é truncado com reticências.
---
--- # Highlight
---
--- * Cada captura da query vira `{ hl = "@captura.lang" }` (`@keyword.lua`): são os grupos que
---   o Neovim e os esquemas de cores já definem para o treesitter, com a queda para `@keyword`
---   quando o esquema não define o grupo da linguagem. `lang` é o nome do parser, não o do
---   info string: `sh` vira `bash`, `js` vira `javascript`.
--- * Só a linguagem do bloco: sem injeção (HTML com `<script>`, comentário de doc).
--- * Parser ausente, query ausente, erro: o bloco sai sem cor, sem erro e sem `vim.notify`.
---   O motivo fica em `M.last_error`. Degradar aqui é o caso comum, não o excepcional.
--- * `markdown` e `markdown_inline` não são coloridos: o scanner do parser de Markdown aborta
---   o Neovim com aninhamento fundo (V6) e `parse.lua` é quem tem a guarda, não este módulo.
--- * Acima de `MAX_HIGHLIGHT_LINES` linhas ou `MAX_HIGHLIGHT_BYTES` bytes o bloco sai sem cor.
--- * Tab vira espaços (`TABSTOP`) antes de medir e de marcar, mas o parser recebe o texto
---   original: `Makefile` e afins dependem do tab.
--- * O resultado do parse é guardado por `lang .. fonte`: o preview re-renderiza o documento
---   inteiro a cada edição, e reparsear todo bloco de código a cada vez seria desperdício.
---
--- # Para quem chama este módulo (a fase 7, mermaid)
---
--- `render(block, ctx)` só lê `block.lang`, `block.lines` e `block.note`, então um bloco
--- sintético serve:
---
--- ```lua
--- local lines, marks = require("deckle.render.code").render({
---   lang = "mermaid",                    -- rótulo da moldura; `nil` dá moldura sem rótulo
---   lines = { "graph TD", "  A --> B" }, -- sem "\n", sem cerca, sem prefixo
---   note = "mermaid: native module not loaded", -- opcional
--- }, ctx)
--- ```
---
--- `note` é uma linha discreta (`DeckleCodeNote`) logo abaixo da moldura, truncada em
--- `ctx.width`. Bloco sem linhas não produz nada, nem a nota. De `ctx` só `width` e `charset`
--- são lidos, e faltando um deles vale 80 e ASCII.

local util = require("deckle.render.util")

local M = {}

--- Largura de um tab, em células. Fixa: o render não depende do `tabstop` de ninguém.
M.TABSTOP = 4

--- Acima de qualquer um dos dois o bloco sai sem cor: um parse sem teto trava o re-render.
M.MAX_HIGHLIGHT_LINES = 5000
M.MAX_HIGHLIGHT_BYTES = 512 * 1024

--- Prioridade das marcas de captura, a do highlighter do Neovim (`vim.hl.priorities`). O fundo
--- do bloco fica abaixo, para uma captura com `bg` do esquema vencer.
M.PRIORITY = 100
M.BODY_PRIORITY = 50

--- Motivo da última falha de highlight que este módulo engoliu, ou `nil`. Para teste e
--- depuração: o erro não vai para `vim.notify`, que imprimiria a cada re-render.
---@type string|nil
M.last_error = nil

--- Contadores do cache: `parses` é quantas vezes o treesitter foi chamado de fato, e `hits`
--- quantos blocos saíram do cache. Para teste.
M.stats = { parses = 0, hits = 0 }

--- Nomes de info string que não são nome de parser. O que o usuário registrou com
--- `vim.treesitter.language.register` vem antes desta tabela.
---@type table<string, string>
M.ALIASES = {
  sh = "bash",
  shell = "bash",
  zsh = "bash",
  js = "javascript",
  jsx = "javascript",
  mjs = "javascript",
  cjs = "javascript",
  ts = "typescript",
  mts = "typescript",
  cts = "typescript",
  py = "python",
  python3 = "python",
  rb = "ruby",
  rs = "rust",
  kt = "kotlin",
  yml = "yaml",
  jsonc = "json",
  md = "markdown",
  htm = "html",
  viml = "vim",
  vimscript = "vim",
  h = "c",
  cc = "cpp",
  cxx = "cpp",
  hpp = "cpp",
  ["c++"] = "cpp",
  cs = "c_sharp",
  csharp = "c_sharp",
  ["c#"] = "c_sharp",
  golang = "go",
  ps1 = "powershell",
  pwsh = "powershell",
  tex = "latex",
  patch = "diff",
  ["objective-c"] = "objc",
}

--- Parsers que não são coloridos (ver o topo do módulo).
local NEVER = { markdown = true, markdown_inline = true }

local GLYPHS = {
  unicode = {
    tl = "╭",
    tr = "╮",
    bl = "╰",
    br = "╯",
    h = "─",
    v = "│",
    ellipsis = "…",
  },
  ascii = {
    tl = "+",
    tr = "+",
    bl = "+",
    br = "+",
    h = "-",
    v = "|",
    ellipsis = "...",
  },
}

-- ---------------------------------------------------------------------------------------
-- Texto
-- ---------------------------------------------------------------------------------------

--- Controle (inclusive tab e "\n") vira espaço: rótulo e nota são uma linha só.
---@param s string
---@return string
local function flatten(s)
  return (s:gsub("%c", " "))
end

--- Corta `s` em `max` células no máximo, com `ellipsis` no fim quando sobra espaço para ele.
--- Nunca parte um cluster (emoji com ZWJ, letra com acento combinante).
---@param s string
---@param max integer
---@param ellipsis string
---@return string
local function truncate(s, max, ellipsis)
  if util.width(s) <= max then
    return s
  end
  local keep = ellipsis
  local budget = max - util.width(ellipsis)
  if budget < 1 then
    keep, budget = "", max
  end
  local out, used = {}, 0
  for _, cluster in ipairs(util.clusters(s)) do
    local cells = util.width(cluster)
    if used + cells > budget then
      break
    end
    out[#out + 1] = cluster
    used = used + cells
  end
  return table.concat(out) .. keep
end

--- Troca os tabs de `line` por espaços, até o próximo múltiplo de `TABSTOP` (em células, não
--- em bytes).
---
--- O segundo retorno diz como deslocar uma coluna do texto original para o expandido, e é
--- `nil` quando a linha não tem tab: uma lista de `{ byte do tab, bytes a mais até ali }`,
--- com os bytes 0-indexados.
---@param line string
---@return string expanded
---@return integer[][]|nil shifts
local function expand_tabs(line)
  if not line:find("\t", 1, true) then
    return line, nil
  end
  local out, shifts = {}, {}
  local cell, extra, from = 0, 0, 1
  while true do
    local tab = line:find("\t", from, true)
    local piece = line:sub(from, tab and tab - 1 or #line)
    out[#out + 1] = piece
    cell = cell + util.width(piece)
    if not tab then
      break
    end
    local spaces = M.TABSTOP - cell % M.TABSTOP
    out[#out + 1] = string.rep(" ", spaces)
    cell = cell + spaces
    extra = extra + spaces - 1
    shifts[#shifts + 1] = { tab - 1, extra }
    from = tab + 1
  end
  return table.concat(out), shifts
end

--- Coluna (byte, 0-indexada) do texto original no texto com os tabs expandidos. Uma coluna
--- logo antes de um tab fica antes dos espaços dele, e logo depois, depois deles.
---@param shifts integer[][]
---@param col integer
---@return integer
local function shifted(shifts, col)
  local extra = 0
  for i = 1, #shifts do
    if shifts[i][1] >= col then
      break
    end
    extra = shifts[i][2]
  end
  return col + extra
end

-- ---------------------------------------------------------------------------------------
-- Linguagem
-- ---------------------------------------------------------------------------------------

---@param lang string
---@return boolean
local function parser_available(lang)
  local ok, loaded = pcall(vim.treesitter.language.add, lang)
  return ok and loaded ~= nil and loaded ~= false
end

--- O nome do parser de um nome de info string, ou `nil` se nenhum dos candidatos tem parser.
---
--- Candidatos, na ordem: o que `vim.treesitter.language.get_lang` devolve (que respeita o
--- `register` do usuário), `M.ALIASES`, a extensão como filetype (`py` -> `python`) e o nome
--- como veio. Só nomes `[%w_]+` chegam ao `language.add`: ele procura `parser/<nome>.*` no
--- runtimepath, e o info string vem de um documento que ninguém conferiu.
---@param name string|nil
---@return string|nil
function M.resolve_lang(name)
  if type(name) ~= "string" then
    return nil
  end
  name = name:lower()
  if name == "" then
    return nil
  end

  local tried = {}
  local function try(candidate)
    if type(candidate) ~= "string" or tried[candidate] or not candidate:match("^[%w_]+$") then
      return nil
    end
    tried[candidate] = true
    if parser_available(candidate) then
      return candidate
    end
  end

  local ok, registered = pcall(vim.treesitter.language.get_lang, name)
  local found = (ok and try(registered)) or try(M.ALIASES[name])
  if found then
    return found
  end
  if name:match("^[%w_]+$") then
    local matched, filetype = pcall(vim.filetype.match, { filename = "x." .. name })
    if matched and filetype then
      local resolved, lang = pcall(vim.treesitter.language.get_lang, filetype)
      found = try(resolved and lang or filetype)
      if found then
        return found
      end
    end
  end
  return try(name)
end

-- ---------------------------------------------------------------------------------------
-- Highlight
-- ---------------------------------------------------------------------------------------

--- Capturas de um parse: lista plana com seis campos por captura, que é bem mais leve de
--- guardar do que uma tabela por captura: `row, col, end_row, end_col, grupo, prioridade`,
--- as posições 0-indexadas, em bytes, do texto original.
local STRIDE = 6

--- Capturas que o highlighter também ignora (`_privada`) ou que não têm cor própria.
local SKIP = { spell = true, nospell = true, none = true }

---@param capture string
---@param lang string
---@return string|false
local function group_of(capture, lang)
  if capture:sub(1, 1) == "_" or SKIP[capture] then
    return false
  end
  return "@" .. capture .. "." .. lang
end

--- Roda o treesitter. Lança em qualquer falha; quem chama captura.
---@param lang string
---@param src string
---@return integer[]|nil captures `nil` se a linguagem não tem query de highlights
local function parse_captures(lang, src)
  local query = vim.treesitter.query.get(lang, "highlights")
  if not query then
    return nil
  end

  M.stats.parses = M.stats.parses + 1
  local parser = vim.treesitter.get_string_parser(src, lang)
  -- Sem argumento: só a linguagem do bloco. `parse(true)` rodaria as injeções.
  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then
    return nil
  end

  local out, n = {}, 0
  local groups = {}
  for id, node, metadata in query:iter_captures(tree:root(), src) do
    local group = groups[id]
    if group == nil then
      group = group_of(query.captures[id], lang)
      groups[id] = group
    end
    if group then
      local own = metadata and metadata[id]
      local sr, sc, er, ec
      if own and own.range then
        -- `#offset!` e afins mudam o intervalo que a captura realmente cobre.
        local ok, a, b, _, c, d = pcall(vim.treesitter.get_range, node, src, own)
        if ok then
          sr, sc, er, ec = a, b, c, d
        end
      end
      if not sr then
        sr, sc, er, ec = node:range()
      end
      local priority = tonumber(metadata and metadata.priority)
        or tonumber(own and own.priority)
        or M.PRIORITY
      out[n + 1], out[n + 2], out[n + 3], out[n + 4] = sr, sc, er, ec
      out[n + 5], out[n + 6] = group, priority
      n = n + STRIDE
    end
  end
  return out
end

--- Teto do cache, por geração (abaixo): quantas entradas e quantas capturas no total. Um bloco
--- com mais da metade do teto de capturas não entra.
M.MAX_CACHE_ENTRIES = 256
M.MAX_CACHE_WEIGHT = 300000

-- Cache de duas gerações: um acerto na antiga promove a entrada para a nova, e a antiga é
-- descartada quando a nova enche. Documento com mais blocos do que cabe numa geração ainda
-- reaproveita metade, em vez de perder tudo a cada render como um cache que se esvazia inteiro.
local cache = { young = {}, old = {}, entries = 0, weight = 0 }

---@param key string
---@param captures integer[]
local function cache_put(key, captures)
  local weight = #captures / STRIDE
  if weight > M.MAX_CACHE_WEIGHT / 2 then
    return
  end
  if cache.entries >= M.MAX_CACHE_ENTRIES or cache.weight + weight > M.MAX_CACHE_WEIGHT then
    cache.old, cache.young, cache.entries, cache.weight = cache.young, {}, 0, 0
  end
  cache.young[key] = captures
  cache.entries = cache.entries + 1
  cache.weight = cache.weight + weight
end

---@param key string
---@return integer[]|nil
local function cache_get(key)
  local hit = cache.young[key]
  if hit then
    return hit
  end
  hit = cache.old[key]
  if hit then
    cache_put(key, hit)
  end
  return hit
end

--- Esvazia o cache. Para teste.
function M.clear_cache()
  cache = { young = {}, old = {}, entries = 0, weight = 0 }
end

--- Quantas entradas o cache guarda, nas duas gerações. Para teste.
---@return integer
function M.cache_size()
  return vim.tbl_count(cache.young) + vim.tbl_count(cache.old)
end

--- As capturas de `lines` na linguagem `lang`, ou `nil` se o bloco sai sem cor. Nunca lança.
---@param lines string[]
---@param lang string|nil
---@return integer[]|nil
local function highlight(lines, lang)
  local resolved = M.resolve_lang(lang)
  if not resolved or NEVER[resolved] or #lines > M.MAX_HIGHLIGHT_LINES then
    return nil
  end
  local src = table.concat(lines, "\n")
  if #src > M.MAX_HIGHLIGHT_BYTES then
    return nil
  end

  local key = resolved .. "\0" .. src
  local hit = cache_get(key)
  if hit then
    M.stats.hits = M.stats.hits + 1
    return hit
  end

  local ok, captures = pcall(parse_captures, resolved, src)
  if not ok then
    M.last_error = tostring(captures)
    return nil
  end
  if captures == nil then
    M.last_error = ("no highlights query for %q"):format(resolved)
    return nil
  end
  -- Falha não entra no cache: instalar o parser no meio da sessão tem que fazer efeito.
  cache_put(key, captures)
  return captures
end

--- Capturas -> marcas, uma por linha coberta, no texto da caixa.
---@param captures integer[]
---@param raw string[] as linhas originais
---@param shifts (integer[][]|false)[] deslocamento de tab de cada linha
---@param base integer bytes à esquerda do texto em cada linha da caixa
---@param first_row integer linha da caixa onde está a primeira linha de código
---@param marks deckle.Mark[]
local function add_capture_marks(captures, raw, shifts, base, first_row, marks)
  local rows = #raw
  for i = 1, #captures, STRIDE do
    local sr, sc, er, ec = captures[i], captures[i + 1], captures[i + 2], captures[i + 3]
    local group, priority = captures[i + 4], captures[i + 5]
    for row = sr, math.min(er, rows - 1) do
      local line = raw[row + 1]
      local from = row == sr and sc or 0
      local to = row == er and math.min(ec, #line) or #line
      if to > from then
        local sh = shifts[row + 1]
        if sh then
          from, to = shifted(sh, from), shifted(sh, to)
        end
        marks[#marks + 1] = {
          row = first_row + row,
          col = base + from,
          end_col = base + to,
          hl = group,
          priority = priority,
        }
      end
    end
  end
end

-- ---------------------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------------------

---@param block deckle.Block|{ lang: string|nil, lines: string[]|nil, note: string|nil }
---@param ctx deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(block, ctx)
  local source = type(block) == "table" and block.lines or nil
  if type(source) ~= "table" or #source == 0 then
    return {}, {}
  end
  ctx = ctx or {}
  local g = GLYPHS[ctx.charset] or GLYPHS.ascii
  local width = math.max(ctx.width or 80, util.MIN_WIDTH)

  -- Texto: o original (para o parser), o expandido (para a caixa) e a largura de cada linha.
  local raw, text, widths, shifts = {}, {}, {}, {}
  local widest = 0
  for i = 1, #source do
    local line = source[i]
    if type(line) ~= "string" then
      line = tostring(line)
    end
    if line:find("\n", 1, true) then
      line = line:gsub("\n", " ")
    end
    raw[i] = line
    local expanded, shift = expand_tabs(line)
    text[i] = expanded
    shifts[i] = shift or false
    widths[i] = util.width(expanded)
    widest = math.max(widest, widths[i])
  end
  local captures = highlight(raw, block.lang)

  -- Medidas da caixa. Com `ambiwidth=double` os glifos de borda ocupam duas células, e a
  -- caixa cresce o necessário para o traço fechar certo; fora isso `hw` e `cw` são 1.
  local vw, hw, cw = util.width(g.v), util.width(g.h), util.width(g.tl)
  local gutter = vw + 1
  local total = math.max(width, widest + 2 * gutter)
  local slack = (total - 2 * cw) % hw
  if slack ~= 0 then
    total = total + hw - slack
  end

  -- Borda de cima, com o rótulo.
  local label = block.lang ~= nil and flatten(tostring(block.lang)) or ""
  if label ~= "" then
    local room = total - 2 * cw - 2 * hw - 2
    label = room >= 1 and truncate(label, room, g.ellipsis) or ""
  end
  local top, label_from, label_to
  if label ~= "" then
    local rest = total - 2 * cw - hw - 2 - util.width(label)
    local strokes = math.floor(rest / hw)
    local lead = g.tl .. g.h .. " "
    top = lead
      .. label
      .. " "
      .. string.rep(" ", rest - strokes * hw)
      .. string.rep(g.h, strokes)
      .. g.tr
    label_from, label_to = #lead, #lead + #label
  else
    top = g.tl .. string.rep(g.h, math.floor((total - 2 * cw) / hw)) .. g.tr
  end

  local lines = { top }
  local marks = {}
  if label_from then
    marks[1] = { row = 0, col = 0, end_col = label_from, hl = "DeckleCodeBorder" }
    marks[2] = { row = 0, col = label_from, end_col = label_to, hl = "DeckleCodeLang" }
    marks[3] = { row = 0, col = label_to, end_col = #top, hl = "DeckleCodeBorder" }
  else
    marks[1] = { row = 0, col = 0, end_col = #top, hl = "DeckleCodeBorder" }
  end

  -- Corpo: borda, espaço, código, enchimento até a largura da caixa, espaço, borda.
  local left, right = g.v .. " ", " " .. g.v
  local fill = total - 2 * gutter
  for i = 1, #text do
    local line = left .. text[i] .. string.rep(" ", fill - widths[i]) .. right
    lines[i + 1] = line
    marks[#marks + 1] = { row = i, col = 0, end_col = #g.v, hl = "DeckleCodeBorder" }
    marks[#marks + 1] = {
      row = i,
      col = #g.v,
      end_col = #line - #g.v,
      hl = "DeckleCode",
      priority = M.BODY_PRIORITY,
    }
    marks[#marks + 1] = { row = i, col = #line - #g.v, end_col = #line, hl = "DeckleCodeBorder" }
  end
  if captures then
    add_capture_marks(captures, raw, shifts, #left, 1, marks)
  end

  -- Borda de baixo e a nota.
  local bottom = g.bl .. string.rep(g.h, math.floor((total - 2 * cw) / hw)) .. g.br
  lines[#lines + 1] = bottom
  marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #bottom, hl = "DeckleCodeBorder" }

  local note = type(block.note) == "string" and vim.trim(flatten(block.note)) or ""
  if note ~= "" then
    note = truncate(note, width, g.ellipsis)
    lines[#lines + 1] = note
    marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #note, hl = "DeckleCodeNote" }
  end
  return lines, marks
end

return M
