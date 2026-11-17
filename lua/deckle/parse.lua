--- Fonte Markdown -> IR (fase 1).
---
--- Treesitter entra (parsers `markdown` e `markdown_inline`, ambos do core do Neovim), uma
--- lista plana de blocos sai. Este módulo não toca em janela, em buffer de saída nem em
--- largura de texto: quem consome o IR (render, sync) é das fases seguintes e depende da
--- forma descrita abaixo. Mudar um campo aqui é mudar o contrato delas.
---
--- # Convenções
---
--- * Linhas são **0-indexadas com fim exclusivo** (`src_start` inclusive, `src_end` exclusive),
---   as mesmas do treesitter e de `nvim_buf_get_lines`. Valem para todo bloco, inclusive os
---   filhos de `quote` e os `items` de `list`: os índices são sempre do documento inteiro.
--- * `src_end` nunca inclui linhas em branco finais, mesmo quando o treesitter inclui
---   (listas, html e código indentado terminam depois da linha em branco), nem linhas só de
---   `>` soltas no fim de um quote. O recorte `lines[src_start + 1 .. src_end]` é o texto do
---   bloco: um quote ou item que contém um filho cobre a linha dele, mesmo que seja só `>`.
--- * Irmãos saem em ordem e sem sobreposição, e todo filho (`children` de `quote`, `items` e
---   os `children` deles) está dentro do intervalo do pai. Vale para qualquer entrada: se a
---   árvore do treesitter vier quebrada (`ERROR`), o intervalo é corrigido, não repassado.
--- * Colunas não aparecem no IR. Quem precisar de coluna lê o fonte.
--- * Nada aqui lança. Bloco desconhecido ou erro do treesitter vira `paragraph` com o texto
---   cru; documento que o treesitter não aguenta vira uma lista de `paragraph` cru.
---
--- # Spans (texto inline)
---
--- Um span é uma tabela com `kind`:
---
--- ```lua
--- { kind = "text",     text = "..." }
--- { kind = "code",     text = "..." }
--- { kind = "strong",   children = { span... } }
--- { kind = "emphasis", children = { span... } }
--- { kind = "link",     href = "...", children = { span... } }
--- { kind = "image",    alt = "...", src = "..." }
--- { kind = "break" }
--- ```
---
--- * `text` e `code` carregam `text`. Em `text`, `"\n"` é quebra **suave** de linha: o
---   prefixo de continuação (`> `, indentação de item) já foi removido. Tratar como espaço.
--- * `break` é quebra **forçada** (dois espaços ou barra no fim da linha).
--- * `strong`, `emphasis` e `link` aninham: `**a *b* c**` é um `strong` cujos `children` têm
---   um `emphasis` no meio. `link` pode ter `image` dentro (selo de README).
--- * `link.href` é `""` para `[a]()`. Link de referência (`[a][r]`, `[a]`) é resolvido pela
---   definição `[r]: url` do documento; sem definição, o texto fica cru, como manda o
---   CommonMark.
--- * `image.alt` é o texto simples da descrição, sem marcação. `image.src` é a URL.
--- * Texto adjacente é sempre fundido num `text` só, e `text` vazio não existe.
--- * Passam crus, dentro de `text`: tachado (`~~x~~`), entidades (`&amp;`) e tags HTML inline.
---   `\*` vira `*`.
---
--- # Blocos
---
--- Todo bloco tem `kind`, `src_start` e `src_end`.
---
--- ```lua
--- { kind = "heading",   level = 1..6, spans = { span... } }
--- { kind = "paragraph", spans = { span... } }
--- { kind = "code",      lang = "rust"|nil, lines = { "..." } }
--- { kind = "quote",     children = { block... } }
--- { kind = "rule" }
--- { kind = "html",      lines = { "..." } }
--- { kind = "list",      ordered = boolean, start = integer|nil, items = { item... } }
--- { kind = "table",     header = { cell... }, rows = { { cell... }... }, align = {...} }
--- ```
---
--- * `heading` cobre ATX e setext. No setext, `src_end` inclui a linha do sublinhado.
--- * `code` cobre cerca (``` e ~~~) e bloco indentado. `lang` é só a primeira palavra do
---   info string e é `nil` sem info string ou no bloco indentado. `lines` não tem a cerca,
---   o prefixo de quote/item nem o recuo do bloco indentado, e não tem `"\n"` no fim.
--- * `html` guarda o HTML cru em `lines`, sem o prefixo de quote/item.
--- * `list`: `start` só existe quando `ordered` (é o número do primeiro item). Cada item é
---   `{ spans, children, checked?, src_start, src_end }`. `spans` é o texto da primeira linha
---   do item (`{}` se o item abre com outra coisa, como um bloco de código). `children` são
---   os blocos seguintes: parágrafos extras, sublistas, código. `checked` é `true`/`false`
---   em item de tarefa (`[x]`/`[ ]`) e `nil` nos demais.
--- * `table`: `header` e cada linha de `rows` são listas de células, e uma célula é uma lista
---   de spans (aparada). As linhas **não** são normalizadas: uma linha com menos células
---   que o cabeçalho fica com menos células. `align[i]` é `"left"`, `"center"`, `"right"`
---   ou `nil`. `align` tem buracos: **nunca use `#align`**, use `#header` para saber o
---   número de colunas. Tabela sem corpo tem `rows = {}`.
---
--- `link_reference_definition` (`[r]: url`) não gera bloco: só alimenta a resolução de
--- links. Front matter (`---` no topo) cai no caminho de bloco desconhecido: `paragraph`.
---
--- # Limites
---
--- * `MAX_NESTING`: o scanner externo do parser de Markdown **aborta o processo** (SIGABRT,
---   exit 134, sem `pcall` que segure) quando há mais de ~200 contêineres abertos. Antes de
---   chamar o treesitter, uma varredura barata estima a profundidade de cada linha; acima do
---   limite o documento inteiro cai no caminho cru. Medido em `docs/validation.md`.
--- * `MAX_DEPTH`: profundidade de contêineres (`quote`, `list`) no IR. O que passar disso
---   vira `paragraph` cru, então a recursão do próprio módulo tem teto.

local M = {}

---@alias deckle.SpanKind "text"|"code"|"strong"|"emphasis"|"link"|"image"|"break"

---@class deckle.Span
---@field kind deckle.SpanKind
---@field text string|nil       `text` e `code`
---@field children deckle.Span[]|nil  `strong`, `emphasis` e `link`
---@field href string|nil       `link`
---@field alt string|nil        `image`
---@field src string|nil        `image`

---@alias deckle.Align "left"|"center"|"right"

---@class deckle.Block
---@field kind "heading"|"paragraph"|"code"|"quote"|"rule"|"html"|"list"|"table"
---@field src_start integer     inclusive, 0-indexado
---@field src_end integer       exclusive
---@field level integer|nil     `heading`, 1 a 6
---@field spans deckle.Span[]|nil  `heading` e `paragraph`
---@field lang string|nil       `code`
---@field lines string[]|nil    `code` e `html`
---@field children deckle.Block[]|nil  `quote`
---@field ordered boolean|nil   `list`
---@field start integer|nil     `list` ordenada
---@field items deckle.ListItem[]|nil  `list`
---@field header deckle.Span[][]|nil   `table`
---@field rows deckle.Span[][][]|nil   `table`
---@field align table<integer, deckle.Align>|nil  `table`, com buracos

---@class deckle.ListItem
---@field spans deckle.Span[]
---@field children deckle.Block[]
---@field checked boolean|nil
---@field src_start integer
---@field src_end integer

M.MAX_DEPTH = 32
M.MAX_NESTING = 64

--- Último erro que `parse_lines` engoliu para cair no caminho cru, ou `nil` se a última
--- chamada correu bem. Só para teste e depuração.
---@type string|nil
M.last_error = nil

--- Profundidade máxima de spans aninhados. Passou disso, o resto fica como texto cru.
local MAX_INLINE_DEPTH = 32

--- Contexto de uma chamada de `parse_lines`.
---@class deckle.ParseCtx
---@field lines string[]
---@field text string                 `lines` unidas por "\n" mais um "\n" final
---@field starts integer[]            offset de byte (0-indexado) do começo de cada linha
---@field defs table<string, string>  rótulo normalizado -> destino
---@field inline table<integer, deckle.InlineTree>  offset de byte de início -> árvore inline

---@class deckle.InlineTree
---@field root TSNode
---@field segs integer[][]            {início, fim} em bytes de cada região incluída

---@param s string
---@return boolean
local function is_blank(s)
  return not s:find("%S")
end

-- ---------------------------------------------------------------------------------------
-- Entrada e caminho cru
-- ---------------------------------------------------------------------------------------

--- Normaliza a entrada para uma lista de linhas sem "\n".
---@param input string|string[]
---@return string[]
local function to_lines(input)
  if type(input) == "string" then
    local text = input:gsub("\r\n", "\n")
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
      -- "a\nb\n" são duas linhas, não três: o "\n" final termina a última.
      lines[#lines] = nil
    end
    return lines
  end

  local lines = {}
  for i = 1, #input do
    local line = input[i]
    if type(line) ~= "string" then
      line = tostring(line)
    end
    -- Um "\n" dentro do elemento (NUL do buffer vem assim) desalinharia todas as linhas
    -- seguintes do treesitter. Trocar mantém o índice de cada linha igual ao do buffer.
    if line:find("\n", 1, true) then
      line = line:gsub("\n", " ")
    end
    lines[i] = line
  end
  return lines
end

--- Caminho de degradação: um `paragraph` cru por trecho entre linhas em branco. Entra
--- quando o treesitter falha ou quando a guarda de aninhamento barra o documento.
---@param lines string[]
---@return deckle.Block[]
local function raw_blocks(lines)
  local out = {}
  local n = #lines
  local i = 1
  while i <= n do
    if is_blank(lines[i]) then
      i = i + 1
    else
      local j = i
      while j < n and not is_blank(lines[j + 1]) do
        j = j + 1
      end
      out[#out + 1] = {
        kind = "paragraph",
        spans = { { kind = "text", text = table.concat(lines, "\n", i, j) } },
        src_start = i - 1,
        src_end = j,
      }
      i = j + 1
    end
  end
  return out
end

--- Estimativa por excesso de quantos contêineres uma linha abre: marcadores `>` e de lista,
--- mais um nível para cada 2 colunas de recuo que antecedem um marcador (um item aninhado
--- precisa de pelo menos 2). Recuo que antecede texto comum não conta.
---@param line string
---@param limit integer
---@return integer
local function line_nesting(line, limit)
  local depth, pending, i, n = 0, 0, 1, #line
  while i <= n do
    local c = line:byte(i)
    if c == 32 then
      pending = pending + 1
      i = i + 1
    elseif c == 9 then
      pending = pending + 4
      i = i + 1
    else
      local step
      if c == 62 then -- ">"
        step = 1
      else
        local marker = line:match("^[-+*][ \t]", i) or line:match("^%d+[.)][ \t]", i)
        -- Deixa o espaço depois do marcador para o próximo giro, onde ele vira recuo.
        step = marker and (#marker - 1) or nil
      end
      if not step then
        break
      end
      depth = depth + 1 + math.floor(pending / 2)
      pending = 0
      i = i + step
      if depth > limit then
        return depth
      end
    end
  end
  return depth
end

---@param lines string[]
---@return boolean
local function too_nested(lines)
  for i = 1, #lines do
    if line_nesting(lines[i], M.MAX_NESTING) > M.MAX_NESTING then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------------------
-- Spans
-- ---------------------------------------------------------------------------------------

--- Texto simples de uma lista de spans, sem marcação.
---@param spans deckle.Span[]
---@return string
function M.plain_text(spans)
  local parts = {}
  for _, span in ipairs(spans) do
    if span.kind == "text" or span.kind == "code" then
      parts[#parts + 1] = span.text
    elseif span.kind == "break" then
      parts[#parts + 1] = "\n"
    elseif span.kind == "image" then
      parts[#parts + 1] = span.alt
    elseif span.children then
      parts[#parts + 1] = M.plain_text(span.children)
    end
  end
  return table.concat(parts)
end

--- Acrescenta texto, fundindo com o `text` anterior.
---@param out deckle.Span[]
---@param text string
local function add_text(out, text)
  if text == "" then
    return
  end
  local last = out[#out]
  if last and last.kind == "text" then
    last.text = last.text .. text
  else
    out[#out + 1] = { kind = "text", text = text }
  end
end

--- Tira o espaço das pontas da lista de spans, removendo `text` que ficar vazio.
---@param spans deckle.Span[]
---@return deckle.Span[]
local function trim_spans(spans)
  while spans[1] and spans[1].kind == "text" do
    local text = spans[1].text:gsub("^%s+", "")
    if text == "" then
      table.remove(spans, 1)
    else
      spans[1].text = text
      break
    end
  end
  while spans[#spans] and spans[#spans].kind == "text" do
    local text = spans[#spans].text:gsub("%s+$", "")
    if text == "" then
      spans[#spans] = nil
    else
      spans[#spans].text = text
      break
    end
  end
  return spans
end

---@param node TSNode
---@param kind string
---@return TSNode|nil
local function child_of_type(node, kind)
  for child in node:iter_children() do
    if child:type() == kind then
      return child
    end
  end
  return nil
end

---@param node TSNode
---@return integer
local function start_byte(node)
  local _, _, byte = node:start()
  return byte
end

---@param node TSNode
---@return integer
local function end_byte(node)
  local _, _, byte = node:end_()
  return byte
end

--- Estado de uma árvore inline em construção.
---@class deckle.InlineState
---@field ctx deckle.ParseCtx
---@field segs integer[][]

--- Texto entre dois offsets de byte, só das regiões incluídas da árvore. É o que deixa de
--- fora o `> ` e o recuo dos itens no meio de um parágrafo de várias linhas.
---@param st deckle.InlineState
---@param a integer
---@param b integer
---@return string
local function slice(st, a, b)
  if b <= a then
    return ""
  end
  local text = st.ctx.text
  local segs = st.segs
  if #segs == 1 then
    local lo, hi = math.max(a, segs[1][1]), math.min(b, segs[1][2])
    return lo < hi and text:sub(lo + 1, hi) or ""
  end
  local parts = {}
  for _, seg in ipairs(segs) do
    local lo, hi = math.max(a, seg[1]), math.min(b, seg[2])
    if lo < hi then
      parts[#parts + 1] = text:sub(lo + 1, hi)
    end
  end
  return table.concat(parts)
end

---@param st deckle.InlineState
---@param node TSNode
---@return string
local function text_of(st, node)
  return slice(st, start_byte(node), end_byte(node))
end

--- Rótulo de referência normalizado, como o CommonMark pede: caixa e espaço colapsados.
---@param label string
---@return string
local function normalize_label(label)
  local normalized = label:lower():gsub("%s+", " ")
  return vim.trim(normalized)
end

---@param raw string
---@return string
local function strip_brackets(raw)
  local inner = vim.trim(raw):match("^%[(.*)%]$")
  return inner or raw
end

---@param raw string
---@return string
local function clean_destination(raw)
  local dest = vim.trim(raw)
  return dest:match("^<(.*)>$") or dest
end

local build_range

--- Spans de um nó que é só um contêiner de texto (`link_text`, `image_description`).
---@param st deckle.InlineState
---@param node TSNode
---@param depth integer
---@return deckle.Span[]
local function children_of(st, node, depth)
  return build_range(st, node, depth, start_byte(node), end_byte(node))
end

---@param st deckle.InlineState
---@param node TSNode
---@param label_node TSNode|nil
---@param depth integer
---@return deckle.Span|nil
local function reference_link(st, node, label_node, depth)
  local text = child_of_type(node, "link_text")
  local label = label_node and strip_brackets(text_of(st, label_node))
    or (text and text_of(st, text))
  local href = label and st.ctx.defs[normalize_label(label)]
  if not href then
    return nil
  end
  return { kind = "link", href = href, children = text and children_of(st, text, depth + 1) or {} }
end

---@param kind "strong"|"emphasis"
---@return fun(st: deckle.InlineState, node: TSNode, depth: integer): deckle.Span|nil
local function emphasis_handler(kind)
  return function(st, node, depth)
    local delims = {}
    for child in node:iter_children() do
      if child:type() == "emphasis_delimiter" then
        delims[#delims + 1] = child
      end
    end
    -- Metade dos delimitadores abre e metade fecha: 1+1 em `emphasis`, 2+2 em `strong`.
    local a, b = start_byte(node), end_byte(node)
    if #delims >= 2 and #delims % 2 == 0 then
      local half = #delims / 2
      a, b = end_byte(delims[half]), start_byte(delims[half + 1])
    end
    return { kind = kind, children = build_range(st, node, depth + 1, a, b) }
  end
end

--- Um handler devolve o span, ou `nil` para deixar o nó como texto cru (e ainda descer
--- nele, caso tenha spans conhecidos dentro).
---@type table<string, fun(st: deckle.InlineState, node: TSNode, depth: integer): deckle.Span|nil>
local INLINE = {
  strong_emphasis = emphasis_handler("strong"),
  emphasis = emphasis_handler("emphasis"),

  code_span = function(st, node)
    local delims = {}
    for child in node:iter_children() do
      if child:type() == "code_span_delimiter" then
        delims[#delims + 1] = child
      end
    end
    if #delims < 2 then
      return nil
    end
    local inner = slice(st, end_byte(delims[1]), start_byte(delims[#delims]))
    inner = inner:gsub("\n", " ")
    -- CommonMark: um espaço de cada lado sai, a não ser que o conteúdo seja só espaço.
    if inner:match("^ .* $") and inner:find("[^ ]") then
      inner = inner:sub(2, -2)
    end
    return { kind = "code", text = inner }
  end,

  inline_link = function(st, node, depth)
    local text = child_of_type(node, "link_text")
    local dest = child_of_type(node, "link_destination")
    return {
      kind = "link",
      href = dest and clean_destination(text_of(st, dest)) or "",
      children = text and children_of(st, text, depth + 1) or {},
    }
  end,

  full_reference_link = function(st, node, depth)
    return reference_link(st, node, child_of_type(node, "link_label"), depth)
  end,
  collapsed_reference_link = function(st, node, depth)
    return reference_link(st, node, nil, depth)
  end,
  shortcut_link = function(st, node, depth)
    return reference_link(st, node, nil, depth)
  end,

  image = function(st, node, depth)
    local desc = child_of_type(node, "image_description")
    local dest = child_of_type(node, "link_destination")
    local label = child_of_type(node, "link_label")
    local src
    if dest then
      src = clean_destination(text_of(st, dest))
    elseif not label and text_of(st, node):find("%]%(") then
      src = "" -- `![a]()`
    else
      local key = label and strip_brackets(text_of(st, label)) or (desc and text_of(st, desc))
      src = key and st.ctx.defs[normalize_label(key)]
    end
    if not src then
      return nil
    end
    local alt = desc and children_of(st, desc, depth + 1) or {}
    return { kind = "image", alt = M.plain_text(alt), src = src }
  end,

  uri_autolink = function(st, node)
    local raw = text_of(st, node)
    local href = raw:match("^<(.*)>$") or raw
    return { kind = "link", href = href, children = { { kind = "text", text = href } } }
  end,
  email_autolink = function(st, node)
    local raw = text_of(st, node)
    local address = raw:match("^<(.*)>$") or raw
    return {
      kind = "link",
      href = "mailto:" .. address,
      children = { { kind = "text", text = address } },
    }
  end,

  hard_line_break = function()
    return { kind = "break" }
  end,

  backslash_escape = function(st, node)
    return { kind = "text", text = text_of(st, node):sub(2) }
  end,
}

--- Percorre os filhos de `node` a partir de `cursor` e devolve onde parou. O que fica entre
--- um span e outro vira `text`: é assim que o texto solto e os delimitadores de nós que não
--- tratamos (tachado, entidade, tag HTML) chegam ao IR sem lógica própria.
---@param st deckle.InlineState
---@param node TSNode
---@param depth integer
---@param out deckle.Span[]
---@param cursor integer
---@return integer
local function walk(st, node, depth, out, cursor)
  for child in node:iter_children() do
    if child:named() then
      local from = start_byte(child)
      local handler = INLINE[child:type()]
      local span = nil
      if handler and depth < MAX_INLINE_DEPTH and from >= cursor then
        span = handler(st, child, depth)
      end

      if span then
        add_text(out, slice(st, cursor, from))
        if span.kind == "text" then
          add_text(out, span.text)
        else
          out[#out + 1] = span
        end
        cursor = end_byte(child)
      elseif depth < MAX_INLINE_DEPTH and child:child_count() > 0 then
        cursor = walk(st, child, depth + 1, out, cursor)
      end
    end
  end
  return cursor
end

---@param st deckle.InlineState
---@param node TSNode
---@param depth integer
---@param a integer
---@param b integer
---@return deckle.Span[]
function build_range(st, node, depth, a, b)
  local out = {}
  local cursor = walk(st, node, depth, out, a)
  add_text(out, slice(st, cursor, b))
  return out
end

-- ---------------------------------------------------------------------------------------
-- Linhas e intervalos de bloco
-- ---------------------------------------------------------------------------------------

--- Linha sem conteúdo: só espaço e marcadores de quote (`>`).
---@param s string
---@return boolean
local function is_empty_row(s)
  return s:match("^[%s>]*$") ~= nil
end

--- `src_start` e `src_end` de um nó de bloco. O treesitter encerra o nó na coluna 0 da linha
--- seguinte, ou no meio do prefixo dela (o `> ` do quote, o recuo do item), e em alguns
--- blocos só depois das linhas em branco. Aqui o fim é a linha seguinte à última linha com
--- conteúdo do próprio nó.
---@param ctx deckle.ParseCtx
---@param node TSNode
---@return integer src_start, integer src_end
local function src_range(ctx, node)
  local sr, _, er, ec = node:range()
  local stop = er + 1
  -- Se o que antecede a coluna final na última linha é só prefixo, a linha não é do nó.
  if er > sr and is_empty_row((ctx.lines[er + 1] or ""):sub(1, ec)) then
    stop = er
  end
  stop = math.min(stop, #ctx.lines)
  while stop > sr + 1 and is_empty_row(ctx.lines[stop]) do
    stop = stop - 1
  end
  return sr, math.max(stop, sr + 1)
end

--- Linha -> coluna onde o prefixo de continuação (`> `, recuo do item) termina, a partir dos
--- `block_continuation` de `node`. Com `deep`, desce a subárvore inteira (pilha explícita):
--- num `ERROR` os prefixos estão nos netos, não nos filhos.
---@param node TSNode
---@param deep boolean
---@return table<integer, integer>
local function continuation_cuts(node, deep)
  local cut = {}
  local stack = { node }
  while #stack > 0 do
    local current = table.remove(stack)
    for child in current:iter_children() do
      if child:type() == "block_continuation" then
        local row, _, end_row, end_col = child:range()
        if row == end_row then
          cut[row] = end_col
        end
      elseif deep and child:child_count() > 0 then
        stack[#stack + 1] = child
      end
    end
  end
  return cut
end

--- Linhas de texto de um nó de bloco, sem o prefixo que os `block_continuation` cobrem.
---@param ctx deckle.ParseCtx
---@param node TSNode
---@param deep boolean|nil procurar continuações em toda a subárvore, não só nos filhos
---@return string[]
local function node_lines(ctx, node, deep)
  local sr, sc, er, ec = node:range()
  local cut = continuation_cuts(node, deep == true)

  -- Onde o texto da linha `row` começa, descontado o prefixo de continuação.
  local function first_col(row)
    return row == sr and sc or (cut[row] or 0)
  end

  -- Um nó que termina no prefixo da própria linha não tem texto nela.
  local last = er
  if last > sr and ec <= first_col(last) then
    last = last - 1
  end

  local out = {}
  for row = sr, last do
    local line = ctx.lines[row + 1] or ""
    local to = (row == er and ec > 0) and ec or #line
    out[#out + 1] = line:sub(first_col(row) + 1, to)
  end
  return out
end

---@param lines string[]
local function drop_trailing_blank(lines)
  while #lines > 0 and is_blank(lines[#lines]) do
    lines[#lines] = nil
  end
end

--- Offsets de byte do começo de cada linha, no texto que o treesitter lê.
---@param lines string[]
---@return integer[]
local function line_starts(lines)
  local starts = { 0 }
  for i = 1, #lines do
    starts[i + 1] = starts[i] + #lines[i] + 1
  end
  return starts
end

-- ---------------------------------------------------------------------------------------
-- Árvores inline e definições de link
-- ---------------------------------------------------------------------------------------

--- Texto simples de um nó inline cuja árvore não existe: o que sobrou do fonte.
---@param ctx deckle.ParseCtx
---@param node TSNode
---@return deckle.Span[]
local function raw_spans(ctx, node)
  local lines = node_lines(ctx, node)
  local text = vim.trim(table.concat(lines, "\n"))
  return text == "" and {} or { { kind = "text", text = text } }
end

--- Spans de um nó de bloco que contém texto inline (`inline` ou `pipe_table_cell`). Sem a
--- árvore `markdown_inline` correspondente, o texto fica cru em vez de sumir.
---@param ctx deckle.ParseCtx
---@param node TSNode
---@return deckle.Span[]
local function inline_spans(ctx, node)
  local entry = ctx.inline[start_byte(node)]
  if entry then
    local st = { ctx = ctx, segs = entry.segs }
    local root = entry.root
    local ok, spans = pcall(build_range, st, root, 0, start_byte(root), end_byte(root))
    if ok then
      return trim_spans(spans)
    end
  end
  return raw_spans(ctx, node)
end

--- Registra as árvores `markdown_inline` do parser pelo offset de byte em que começam.
---@param ctx deckle.ParseCtx
---@param parser vim.treesitter.LanguageTree
local function index_inline_trees(ctx, parser)
  local inline = parser:children()["markdown_inline"]
  if not inline then
    return
  end
  for _, tree in pairs(inline:trees()) do
    local segs = {}
    for _, range in ipairs(tree:included_ranges(false)) do
      local sr, sc, er, ec = range[1], range[2], range[3], range[4]
      local a, b = ctx.starts[sr + 1], ctx.starts[er + 1]
      if not (a and b) then
        segs = nil
        break
      end
      segs[#segs + 1] = { a + sc, b + ec }
    end
    if segs and #segs > 0 then
      local root = tree:root()
      ctx.inline[start_byte(root)] = { root = root, segs = segs }
    end
  end
end

--- Contêineres onde `link_reference_definition` pode aparecer.
local DEF_CONTAINERS = {
  document = true,
  section = true,
  block_quote = true,
  list = true,
  list_item = true,
}

--- Coleta `[rótulo]: destino` do documento todo, antes de construir qualquer bloco: o uso
--- costuma vir antes da definição. Pilha explícita, sem recursão.
---@param ctx deckle.ParseCtx
---@param root TSNode
local function collect_definitions(ctx, root)
  local stack = { root }
  while #stack > 0 do
    local node = table.remove(stack)
    for child in node:iter_children() do
      local kind = child:type()
      if kind == "link_reference_definition" then
        local label = child_of_type(child, "link_label")
        local dest = child_of_type(child, "link_destination")
        if label and dest then
          local key = normalize_label(strip_brackets(vim.treesitter.get_node_text(label, ctx.text)))
          -- A primeira definição vence, como no CommonMark.
          if ctx.defs[key] == nil then
            ctx.defs[key] = clean_destination(vim.treesitter.get_node_text(dest, ctx.text))
          end
        end
      elseif DEF_CONTAINERS[kind] then
        stack[#stack + 1] = child
      end
    end
  end
end

-- ---------------------------------------------------------------------------------------
-- Blocos
-- ---------------------------------------------------------------------------------------

local dispatch_block

---@param ctx deckle.ParseCtx
---@param node TSNode
---@param fields table
---@return deckle.Block
local function make_block(ctx, node, fields)
  fields.src_start, fields.src_end = src_range(ctx, node)
  return fields
end

--- Estende o fim de um contêiner até o fim do último filho. O corte de linhas só de
--- marcador (`> `) no fim do pai pode deixar de fora a linha de um filho que é exatamente
--- isso, como um quote vazio aninhado.
---@param parent table
---@param children table[]
local function cover(parent, children)
  local last = children[#children]
  if last and last.src_end > parent.src_end then
    parent.src_end = last.src_end
  end
end

--- Garante, para a lista toda, as invariantes de que o resto do plugin depende: irmãos em
--- ordem e sem sobreposição, e filhos dentro do intervalo do pai. Documento bem formado já
--- sai assim e passa direto. Árvore com `ERROR` do treesitter às vezes não: um bloco pode
--- engolir a linha em que o seguinte começa. Neste caso, o que sobrepõe perde o começo, e
--- o que ficou inteiro dentro do anterior some (o texto dele continua no recorte do anterior).
---@param list table[] blocos ou itens de lista
---@param lo integer
---@param hi integer
---@return table[]
local function sanitize(list, lo, hi)
  local out = {}
  local cursor = lo
  for _, node in ipairs(list) do
    node.src_end = math.min(node.src_end, hi)
    if node.src_end > cursor then
      node.src_start = math.max(node.src_start, cursor)
      cursor = node.src_end
      out[#out + 1] = node

      if node.kind == "quote" then
        node.children = sanitize(node.children, node.src_start, node.src_end)
      elseif node.kind == "list" then
        node.items = sanitize(node.items, node.src_start, node.src_end)
        for _, item in ipairs(node.items) do
          item.children = sanitize(item.children, item.src_start, item.src_end)
        end
      end
    end
  end
  return out
end

--- Bloco desconhecido, `ERROR` do parser ou contêiner fundo demais: `paragraph` com o texto
--- cru. Se o trecho só tem linhas em branco, não gera nada.
---@param ctx deckle.ParseCtx
---@param node TSNode
---@param out deckle.Block[]
local function raw_paragraph(ctx, node, out)
  local lines = node_lines(ctx, node, true)
  drop_trailing_blank(lines)
  local lead = 0
  while lead < #lines and is_blank(lines[lead + 1]) do
    lead = lead + 1
  end
  if lead == #lines then
    return
  end
  local sr, stop = src_range(ctx, node)
  out[#out + 1] = {
    kind = "paragraph",
    spans = { { kind = "text", text = table.concat(lines, "\n", lead + 1) } },
    src_start = sr + lead,
    src_end = math.max(stop, sr + lead + 1),
  }
end

---@param kind string
---@return boolean
local function is_structural(kind)
  return kind:find("marker", 1, true) ~= nil or kind:find("continuation", 1, true) ~= nil
end

--- Constrói os blocos dos filhos de `node` e acrescenta a `out`.
---@param ctx deckle.ParseCtx
---@param node TSNode
---@param depth integer
---@param out deckle.Block[]
local function build_blocks(ctx, node, depth, out)
  for child in node:iter_children() do
    if child:named() then
      dispatch_block(ctx, child, depth, out)
    end
  end
end

---@param node TSNode
---@return TSNode|nil
local function first_inline(node)
  local direct = child_of_type(node, "inline")
  if direct then
    return direct
  end
  local paragraph = child_of_type(node, "paragraph")
  return paragraph and child_of_type(paragraph, "inline") or nil
end

--- Tira a sequência de fechamento do ATX (`## título ##`).
---@param spans deckle.Span[]
---@return deckle.Span[]
local function strip_closing_hashes(spans)
  local last = spans[#spans]
  if last and last.kind == "text" then
    local text = last.text:gsub("%s+#+%s*$", "")
    if text == "" then
      spans[#spans] = nil
    else
      last.text = text
    end
  end
  return spans
end

---@param ctx deckle.ParseCtx
---@param node TSNode
---@return deckle.Span[][]
local function table_cells(ctx, node)
  local cells = {}
  for child in node:iter_children() do
    if child:type() == "pipe_table_cell" then
      cells[#cells + 1] = inline_spans(ctx, child)
    end
  end
  return cells
end

---@param node TSNode
---@return table<integer, deckle.Align>
local function table_align(node)
  local align = {}
  local col = 0
  for cell in node:iter_children() do
    if cell:type() == "pipe_table_delimiter_cell" then
      col = col + 1
      local left = child_of_type(cell, "pipe_table_align_left") ~= nil
      local right = child_of_type(cell, "pipe_table_align_right") ~= nil
      if left and right then
        align[col] = "center"
      elseif left then
        align[col] = "left"
      elseif right then
        align[col] = "right"
      end
    end
  end
  return align
end

--- Linhas de um bloco de código indentado: sem o prefixo do contêiner e sem o recuo de 4
--- colunas (ou 1 tab). Não usa os `block_continuation` do nó, porque o treesitter só os
--- emite em algumas linhas e, quando emite, já incluem o recuo: o prefixo do contêiner tem
--- a largura da coluna em que o nó começa, em todas as linhas.
---@param ctx deckle.ParseCtx
---@param node TSNode
---@return string[]
local function indented_lines(ctx, node)
  local sr, sc, er, ec = node:range()
  local last = er
  if er > sr and ec <= sc then
    last = er - 1
  end

  local out = {}
  for row = sr, last do
    local line = (ctx.lines[row + 1] or ""):sub(sc + 1)
    if line:sub(1, 1) == "\t" then
      line = line:sub(2)
    else
      line = line:sub(math.min(#line:match("^ *"), 4) + 1)
    end
    out[#out + 1] = line
  end
  drop_trailing_blank(out)
  return out
end

---@param ctx deckle.ParseCtx
---@param item TSNode
---@param depth integer
---@return deckle.ListItem
local function build_item(ctx, item, depth)
  local spans, children, checked = {}, {}, nil
  local seen_content = false
  for child in item:iter_children() do
    if child:named() then
      local kind = child:type()
      if kind == "task_list_marker_checked" then
        checked = true
      elseif kind == "task_list_marker_unchecked" then
        checked = false
      elseif not is_structural(kind) then
        -- O que sobra depois dos marcadores e dos prefixos de continuação é conteúdo.
        if kind == "paragraph" and not seen_content then
          local inline = child_of_type(child, "inline")
          spans = inline and inline_spans(ctx, inline) or {}
        else
          dispatch_block(ctx, child, depth, children)
        end
        seen_content = true
      end
    end
  end
  local src_start, src_end = src_range(ctx, item)
  local built = {
    spans = spans,
    children = children,
    checked = checked,
    src_start = src_start,
    src_end = src_end,
  }
  cover(built, children)
  return built
end

---@type table<string, fun(ctx: deckle.ParseCtx, node: TSNode, depth: integer, out: deckle.Block[])>
local BLOCK = {}

BLOCK.atx_heading = function(ctx, node, _, out)
  local level = 1
  for child in node:iter_children() do
    local found = child:type():match("^atx_h(%d)_marker$")
    if found then
      level = tonumber(found)
    end
  end
  local inline = child_of_type(node, "inline")
  local spans = inline and strip_closing_hashes(inline_spans(ctx, inline)) or {}
  out[#out + 1] =
    make_block(ctx, node, { kind = "heading", level = level, spans = trim_spans(spans) })
end

BLOCK.setext_heading = function(ctx, node, _, out)
  local level = 1
  for child in node:iter_children() do
    local found = child:type():match("^setext_h(%d)_underline$")
    if found then
      level = tonumber(found)
    end
  end
  local inline = first_inline(node)
  local spans = inline and inline_spans(ctx, inline) or {}
  out[#out + 1] = make_block(ctx, node, { kind = "heading", level = level, spans = spans })
end

BLOCK.paragraph = function(ctx, node, _, out)
  local inline = child_of_type(node, "inline")
  if not inline then
    return raw_paragraph(ctx, node, out)
  end
  out[#out + 1] = make_block(ctx, node, { kind = "paragraph", spans = inline_spans(ctx, inline) })
end

BLOCK.thematic_break = function(ctx, node, _, out)
  out[#out + 1] = make_block(ctx, node, { kind = "rule" })
end

BLOCK.html_block = function(ctx, node, _, out)
  local lines = node_lines(ctx, node)
  drop_trailing_blank(lines)
  out[#out + 1] = make_block(ctx, node, { kind = "html", lines = lines })
end

BLOCK.fenced_code_block = function(ctx, node, _, out)
  local lang, content, fences = nil, nil, 0
  for child in node:iter_children() do
    local kind = child:type()
    if kind == "info_string" then
      local language = child_of_type(child, "language")
      if language then
        local name = vim.treesitter.get_node_text(language, ctx.text)
        lang = name ~= "" and name or nil
      end
    elseif kind == "code_fence_content" then
      content = child
    elseif kind == "fenced_code_block_delimiter" then
      fences = fences + 1
    end
  end
  local lines = content and node_lines(ctx, content) or {}
  if fences < 2 then
    -- Cerca sem fechamento vai até o fim do documento: as em branco finais não são código.
    drop_trailing_blank(lines)
  end
  out[#out + 1] = make_block(ctx, node, { kind = "code", lang = lang, lines = lines })
end

BLOCK.indented_code_block = function(ctx, node, _, out)
  out[#out + 1] = make_block(ctx, node, { kind = "code", lines = indented_lines(ctx, node) })
end

BLOCK.block_quote = function(ctx, node, depth, out)
  if depth >= M.MAX_DEPTH then
    return raw_paragraph(ctx, node, out)
  end
  local children = {}
  build_blocks(ctx, node, depth + 1, children)
  local block = make_block(ctx, node, { kind = "quote", children = children })
  cover(block, children)
  out[#out + 1] = block
end

BLOCK.list = function(ctx, node, depth, out)
  if depth >= M.MAX_DEPTH then
    return raw_paragraph(ctx, node, out)
  end
  local items = {}
  local ordered, start = false, nil
  for child in node:iter_children() do
    if child:type() == "list_item" then
      if #items == 0 then
        for marker in child:iter_children() do
          local kind = marker:type()
          if kind == "list_marker_dot" or kind == "list_marker_parenthesis" then
            ordered = true
            start = tonumber(vim.treesitter.get_node_text(marker, ctx.text):match("%d+"))
          end
        end
      end
      items[#items + 1] = build_item(ctx, child, depth + 1)
    end
  end
  local block = make_block(ctx, node, {
    kind = "list",
    ordered = ordered,
    start = ordered and start or nil,
    items = items,
  })
  cover(block, items)
  out[#out + 1] = block
end

BLOCK.pipe_table = function(ctx, node, _, out)
  local header, rows, align = {}, {}, {}
  for child in node:iter_children() do
    local kind = child:type()
    if kind == "pipe_table_header" then
      header = table_cells(ctx, child)
    elseif kind == "pipe_table_delimiter_row" then
      align = table_align(child)
    elseif kind == "pipe_table_row" then
      rows[#rows + 1] = table_cells(ctx, child)
    end
  end
  out[#out + 1] =
    make_block(ctx, node, { kind = "table", header = header, rows = rows, align = align })
end

--- `section` só agrupa por heading: é transparente, e o IR é plano.
BLOCK.section = function(ctx, node, depth, out)
  build_blocks(ctx, node, depth, out)
end

--- Não gera bloco: só serve para resolver links (ver `collect_definitions`).
BLOCK.link_reference_definition = function() end

---@param ctx deckle.ParseCtx
---@param node TSNode
---@param depth integer
---@param out deckle.Block[]
function dispatch_block(ctx, node, depth, out)
  local kind = node:type()
  local handler = BLOCK[kind]
  if handler then
    handler(ctx, node, depth, out)
  elseif not is_structural(kind) then
    raw_paragraph(ctx, node, out)
  end
end

-- ---------------------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------------------

--- Só interpreta o `markdown` do core e injeta `markdown_inline` nos nós de texto. A query
--- de injeção padrão também carregaria o parser de cada linguagem de code fence, de HTML e
--- de YAML: trabalho à toa, e mais código nativo na frente do editor.
local INJECTIONS = {
  markdown = [[
    ([ (inline) (pipe_table_cell) ] @injection.content
      (#set! injection.language "markdown_inline"))
  ]],
}

---@param lines string[]
---@return deckle.Block[]
local function build(lines)
  if too_nested(lines) then
    return raw_blocks(lines)
  end

  local text = table.concat(lines, "\n") .. "\n"
  local parser = vim.treesitter.get_string_parser(text, "markdown", { injections = INJECTIONS })
  local root = parser:parse(true)[1]:root()

  ---@type deckle.ParseCtx
  local ctx = { lines = lines, text = text, starts = line_starts(lines), defs = {}, inline = {} }
  index_inline_trees(ctx, parser)
  collect_definitions(ctx, root)

  local blocks = {}
  build_blocks(ctx, root, 0, blocks)
  return sanitize(blocks, 0, #lines)
end

--- IR de um documento dado como lista de linhas (ou como texto com "\n").
---
--- Não lança: se algo falhar por dentro, devolve `paragraph` cru por trecho.
---@param input string|string[]
---@return deckle.Block[]
function M.parse_lines(input)
  local ok, lines = pcall(to_lines, input)
  if not ok then
    return {}
  end

  -- Nada a interpretar: IR vazio e válido, sem acordar o parser.
  local blank = true
  for i = 1, #lines do
    if not is_blank(lines[i]) then
      blank = false
      break
    end
  end
  if blank then
    return {}
  end

  local built, blocks = pcall(build, lines)
  if built then
    M.last_error = nil
    return blocks
  end
  -- Sem `vim.notify`: o padrão do Neovim não filtra por nível e imprimiria isto na cara
  -- do usuário a cada re-render. O erro fica aqui para teste e para depuração.
  M.last_error = tostring(blocks)
  return raw_blocks(lines)
end

--- IR do conteúdo de um buffer. Só lê as linhas: o buffer fonte não ganha parser anexado,
--- extmark nem opção (ADR-0003). Buffer inválido dá IR vazio.
---@param bufnr integer|nil `nil` ou `0` é o buffer atual
---@return deckle.Block[]
function M.parse(bufnr)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr or 0, 0, -1, false)
  if not ok then
    return {}
  end
  return M.parse_lines(lines)
end

return M
