-- Testes do render de tabelas (fase 4): `deckle.render.table`.
--
-- O que mais quebra uma tabela é a largura de emoji e CJK, então todo teste de layout mede com
-- `vim.fn.strdisplaywidth` e confere que as bordas verticais caem na mesma coluna de display
-- em toda linha, não que `#linha` bate.
--
-- O dispatcher engole o erro de um módulo de tipo e desenha um aviso no lugar. Por isso todo
-- teste que diz "não lança" confere também `render.last_error == nil`: sem isso, um erro
-- dentro de `table.lua` passaria por tabela renderizada.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local parse = require("deckle.parse")
local render = require("deckle.render")

local T = new_set()

-- ---------------------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------------------

--- Largura de display de `s`: `strdisplaywidth` de cada cluster, somada.
---
--- `strdisplaywidth` da string inteira mede na janela atual e, com `wrap` ligado, conta uma
--- célula a mais quando um caractere largo cai na última coluna dela. Numa linha de tabela
--- mais larga que a janela de teste (80) isso dá falso positivo, e a janela de preview não
--- quebra linha. Os testes de tabela estreita conferem também o `strdisplaywidth` direto.
---@param s string
---@return integer
local function cells(s)
  local total = 0
  for _, cluster in ipairs(vim.fn.split(s, "\\zs")) do
    total = total + vim.fn.strdisplaywidth(cluster)
  end
  return total
end

--- Renderiza `text` (Markdown) na largura 80 e em Unicode, a não ser que `opts` diga outra
--- coisa. Falha o teste se o dispatcher tiver engolido um erro.
---@param text string
---@param opts table|nil
---@return deckle.RenderResult
local function r(text, opts)
  local merged = vim.tbl_extend("force", { width = 80, charset = "unicode" }, opts or {})
  return render.render(parse.parse_lines(text), merged)
end

--- Renderiza um bloco de tabela montado à mão, direto no módulo, sem passar pelo parser.
---@param block table
---@param opts table|nil
---@return deckle.RenderResult
local function render_block(block, opts)
  block.kind = "table"
  block.src_start = 0
  block.src_end = 1
  local merged = vim.tbl_extend("force", { width = 80, charset = "unicode" }, opts or {})
  return render.render({ block }, merged)
end

---@param s string
---@return deckle.Span[]
local function text(s)
  return { { kind = "text", text = s } }
end

---@param lines string[]
---@return integer
local function widest(lines)
  local max = 0
  for _, line in ipairs(lines) do
    max = math.max(max, cells(line))
  end
  return max
end

--- Toda linha tem a mesma largura de display.
---@param lines string[]
---@return integer[] larguras distintas, ordenadas
local function distinct_widths(lines)
  local seen, out = {}, {}
  for _, line in ipairs(lines) do
    local w = cells(line)
    if not seen[w] then
      seen[w] = true
      out[#out + 1] = w
    end
  end
  table.sort(out)
  return out
end

--- Coluna de display de cada glifo estrutural da linha (os que as bordas verticais e as
--- junções ocupam). Numa tabela alinhada, toda linha devolve a mesma lista.
---@param line string
---@param glyphs table<string, boolean>
---@return integer[]
local function structure_columns(line, glyphs)
  local found, col = {}, 0
  for _, cluster in ipairs(vim.fn.split(line, "\\zs")) do
    if glyphs[cluster] then
      found[#found + 1] = col
    end
    col = col + cells(cluster)
  end
  return found
end

local UNICODE_GLYPHS = {}
for _, glyph in ipairs(vim.fn.split("│┌┬┐├┼┤└┴┘", "\\zs")) do
  UNICODE_GLYPHS[glyph] = true
end
local ASCII_GLYPHS = { ["|"] = true, ["+"] = true }

--- As bordas verticais de todas as linhas caem nas mesmas colunas de display.
---@param lines string[]
---@param glyphs table<string, boolean>
local function expect_aligned(lines, glyphs)
  eq(#lines > 0, true)
  local expected = structure_columns(lines[1], glyphs)
  eq(#expected >= 2, true)
  for i, line in ipairs(lines) do
    eq({ i, structure_columns(line, glyphs) }, { i, expected })
  end
  eq(#distinct_widths(lines), 1)
end

--- Texto coberto pelas marcas de `hl`, em ordem de linha e coluna.
---@param result deckle.RenderResult
---@param hl string
---@return string[]
local function marked(result, hl)
  local found = {}
  for _, mark in ipairs(result.marks) do
    if mark.hl == hl then
      found[#found + 1] =
        { mark.row, mark.col, result.lines[mark.row + 1]:sub(mark.col + 1, mark.end_col) }
    end
  end
  table.sort(found, function(a, b)
    if a[1] ~= b[1] then
      return a[1] < b[1]
    end
    return a[2] < b[2]
  end)
  return vim.tbl_map(function(item)
    return item[3]
  end, found)
end

--- Toda marca cai dentro da linha, num intervalo de bytes não vazio e em fronteira de
--- caractere (um byte de continuação no início ou no fim partiria um caractere).
---@param result deckle.RenderResult
---@return string[] violações
local function mark_problems(result)
  local problems = {}
  for i, mark in ipairs(result.marks) do
    local line = result.lines[mark.row + 1]
    if not line then
      problems[#problems + 1] = ("marca %d (%s): sem a linha %d"):format(i, mark.hl, mark.row)
    elseif not (mark.col >= 0 and mark.col < mark.end_col and mark.end_col <= #line) then
      problems[#problems + 1] = ("marca %d (%s): [%d,%d) fora de %d bytes"):format(
        i,
        mark.hl,
        mark.col,
        mark.end_col,
        #line
      )
    else
      local first = line:byte(mark.col + 1)
      local after = line:byte(mark.end_col + 1)
      if first >= 0x80 and first < 0xC0 or (after and after >= 0x80 and after < 0xC0) then
        problems[#problems + 1] = ("marca %d (%s): parte um caractere"):format(i, mark.hl)
      end
    end
  end
  return problems
end

--- Conteúdo de cada célula de uma linha de tabela, sem borda e sem recuo.
---@param line string
---@param bar string
---@return string[]
local function row_cells(line, bar)
  local parts = vim.split(line, bar, { plain = true })
  local out = {}
  for i = 2, #parts - 1 do
    out[#out + 1] = vim.trim(parts[i])
  end
  return out
end

--- Roda `fn` com `ambiwidth` trocado e o restaura em qualquer caso.
---@param value string
---@param fn fun()
local function with_ambiwidth(value, fn)
  local saved = vim.o.ambiwidth
  vim.o.ambiwidth = value
  local ok, err = pcall(fn)
  vim.o.ambiwidth = saved
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------------------
-- Gate 1: emoji e CJK ficam alinhados
-- ---------------------------------------------------------------------------------------

T["alinhamento de largura"] = new_set()

local WIDE_TABLE = table.concat({
  "| Nome | Descrição | Nota |",
  "|:-----|:---------:|-----:|",
  "| 日本語 | 😀😀 | ñ |",
  "| ascii | 👨‍👩‍👧 família | é |", -- ZWJ
  "| 🇧🇷 | ❤️ e 👍🏽 | e\204\129 |", -- bandeira, VS16, tom de pele, combinante
  "| 한국어 テスト | x | 中 |",
  "|  | 中 | |",
}, "\n")

T["alinhamento de largura"]["toda linha tem a mesma strdisplaywidth, em unicode"] = function()
  local result = r(WIDE_TABLE)
  eq(render.last_error, nil)
  eq(#result.lines, 9)
  -- A tabela é mais estreita que a janela de teste: `strdisplaywidth` direto é confiável.
  eq(widest(result.lines) < vim.api.nvim_win_get_width(0), true)
  local first = vim.fn.strdisplaywidth(result.lines[1])
  for _, line in ipairs(result.lines) do
    eq(vim.fn.strdisplaywidth(line), first)
  end
  expect_aligned(result.lines, UNICODE_GLYPHS)
end

T["alinhamento de largura"]["texto mais largo que a janela atual não infla a medida"] = function()
  -- Regressão: com `wrap` ligado, `strdisplaywidth` conta uma célula a mais por caractere
  -- largo na última coluna da janela. A célula passa de 80 células, a janela de teste.
  local saved = vim.wo.wrap
  vim.wo.wrap = true
  local ok, err = pcall(function()
    -- O `x` põe os caracteres largos em colunas ímpares, e um deles cai na última coluna (80).
    local long = "x" .. string.rep("日本語", 40)
    local result = r("| h | h |\n|--|--|\n| " .. long .. " | x |\n| a | b |", { width = 400 })
    eq(render.last_error, nil)
    eq(widest(result.lines) > vim.api.nvim_win_get_width(0), true)
    eq(#distinct_widths(result.lines), 1)
    expect_aligned(result.lines, UNICODE_GLYPHS)
    eq(result.lines[4], "│ " .. long .. " │ x │")
  end)
  vim.wo.wrap = saved
  if not ok then
    error(err, 0)
  end
end

T["alinhamento de largura"]["as bordas verticais caem na mesma coluna, em ascii"] = function()
  local result = r(WIDE_TABLE, { charset = "ascii" })
  eq(render.last_error, nil)
  expect_aligned(result.lines, ASCII_GLYPHS)
end

T["alinhamento de largura"]["a coluna tem a largura da célula mais larga, não a contagem de bytes"] = function()
  -- `日本語` mede 6 células e 9 bytes: a coluna tem 6, não 9.
  local result = r("| h |\n|---|\n| 日本語 |")
  eq(result.lines, {
    "┌────────┐",
    "│ h      │",
    "├────────┤",
    "│ 日本語 │",
    "└────────┘",
  })
  eq(cells(result.lines[1]), 10)
end

T["alinhamento de largura"]["emoji de duas células, ZWJ e combinante medem pelo que o terminal desenha"] = function()
  local result = r("| a |\n|---|\n| 😀 |\n| 👨‍👩‍👧 |\n| e\204\129 |")
  eq(render.last_error, nil)
  -- Mais larga: o emoji, de duas células. O `é` com acento combinante mede uma.
  eq(result.lines[1], "┌────┐")
  eq(result.lines[4], "│ 😀 │")
  eq(result.lines[5], "│ 👨‍👩‍👧 │")
  eq(result.lines[6], "│ e\204\129  │")
  eq(#distinct_widths(result.lines), 1)
end

T["alinhamento de largura"]["ambiwidth=double: caixa de duas células cai para bordas ascii e continua alinhada"] = function()
  with_ambiwidth("double", function()
    -- Pré-condição: nesta configuração `│` ocupa duas células.
    eq(cells("│"), 2)
    local result = r("| a | b |\n|---|---|\n| 日本語 | 😀 |")
    eq(render.last_error, nil)
    eq(result.lines[1], "+--------+----+")
    eq(result.lines[2], "| a      | b  |")
    expect_aligned(result.lines, ASCII_GLYPHS)
  end)
end

-- ---------------------------------------------------------------------------------------
-- Gate 2: nada lança
-- ---------------------------------------------------------------------------------------

T["entrada degenerada"] = new_set()

T["entrada degenerada"]["célula vazia"] = function()
  local result = r("| a | b |\n|---|---|\n|  |  |\n| 1 |  |")
  eq(render.last_error, nil)
  eq(result.lines, {
    "┌───┬───┐",
    "│ a │ b │",
    "├───┼───┤",
    "│   │   │",
    "│ 1 │   │",
    "└───┴───┘",
  })
  eq(mark_problems(result), {})
end

T["entrada degenerada"]["cabeçalho todo vazio"] = function()
  local result = r("|  |  |\n|--|--|\n| a | b |")
  eq(render.last_error, nil)
  eq(#result.lines, 5)
  expect_aligned(result.lines, UNICODE_GLYPHS)
end

T["entrada degenerada"]["tabela sem corpo fecha o cabeçalho direto na borda de baixo"] = function()
  local result = r("| a | b |\n|---|---|")
  eq(render.last_error, nil)
  eq(result.lines, {
    "┌───┬───┐",
    "│ a │ b │",
    "└───┴───┘",
  })
  eq(r("| a | b |\n|---|---|", { charset = "ascii" }).lines, {
    "+---+---+",
    "| a | b |",
    "+---+---+",
  })
end

T["entrada degenerada"]["linha com células a menos é completada com vazias"] = function()
  local result = r("| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 |")
  eq(render.last_error, nil)
  eq(result.lines, {
    "┌───┬───┬───┐",
    "│ a │ b │ c │",
    "├───┼───┼───┤",
    "│ 1 │   │   │",
    "│ 1 │ 2 │   │",
    "└───┴───┴───┘",
  })
end

T["entrada degenerada"]["linha com células a mais perde as extras"] = function()
  local result = r("| a | b |\n|---|---|\n| 1 | 2 | 3 | 4 |")
  eq(render.last_error, nil)
  eq(result.lines, {
    "┌───┬───┐",
    "│ a │ b │",
    "├───┼───┤",
    "│ 1 │ 2 │",
    "└───┴───┘",
  })
  local joined = table.concat(result.lines, "\n")
  eq(joined:find("[34]"), nil)
end

T["entrada degenerada"]["IR montado à mão: cabeçalho ou corpo ausentes, célula nula, align com buraco"] = function()
  -- Nada produz linha: sem colunas não há tabela.
  eq(render_block({}).lines, {})
  eq(render_block({ header = {}, rows = {} }).lines, {})
  eq(render.last_error, nil)

  -- Sem cabeçalho (o parser não gera, mas o IR é público): só o corpo, sem linha de grade.
  eq(render_block({ rows = { { text("a"), text("b") } } }).lines, {
    "┌───┬───┐",
    "│ a │ b │",
    "└───┴───┘",
  })
  eq(render.last_error, nil)

  -- Sem corpo e sem `align`.
  eq(
    render_block({ header = { text("a") } }).lines,
    { "┌───┐", "│ a │", "└───┘" }
  )

  -- `align` com buraco: a coluna 2 não tem alinhamento, a 3 é à direita.
  local result = render_block({
    header = { text("aaa"), text("bbb"), text("ccc") },
    rows = { { text("1"), text("2"), text("3") } },
    align = { [3] = "right" },
  })
  eq(render.last_error, nil)
  eq(result.lines[4], "│ 1   │ 2   │   3 │")

  -- Célula `{}` (sem spans) e linha só com células vazias.
  local sparse = render_block({
    header = { {}, text("b") },
    rows = { { {}, {} }, {} },
  })
  eq(render.last_error, nil)
  expect_aligned(sparse.lines, UNICODE_GLYPHS)
end

T["entrada degenerada"]["quebra forçada dentro da célula vira espaço"] = function()
  local result = render_block({
    header = {
      { { kind = "text", text = "a" }, { kind = "break" }, { kind = "text", text = "b" } },
    },
    rows = {},
  })
  eq(render.last_error, nil)
  eq(result.lines[2], "│ a b │")
end

T["entrada degenerada"]["tabela com muitas colunas transborda a largura em vez de lançar"] = function()
  local header, row = {}, {}
  for i = 1, 30 do
    header[i] = text("c" .. i)
    row[i] = text("valor longo " .. i)
  end
  local result = render_block({ header = header, rows = { row } }, { width = 40 })
  eq(render.last_error, nil)
  -- Cada coluna encolhe ao piso (as reticências), e ainda assim passa de 40.
  eq(widest(result.lines) > 40, true)
  eq(#distinct_widths(result.lines), 1)
  eq(mark_problems(result), {})
end

T["entrada degenerada"]["célula gigante não trava e é truncada"] = function()
  local result = render_block({
    header = { text("a"), text("b") },
    rows = { { text(string.rep("x", 200000)), text("ok") } },
  }, { width = 30 })
  eq(render.last_error, nil)
  eq(widest(result.lines), 30)
  eq(#distinct_widths(result.lines), 1)
end

T["entrada degenerada"]["as fixtures de tabela do parser renderizam sem erro em várias larguras"] = function()
  local lines = vim.fn.readfile(
    vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fixtures/tables.md"
  )
  local ir = parse.parse_lines(lines)
  for _, width in ipairs({ 1, 10, 13, 20, 33, 80, 200 }) do
    for _, charset in ipairs({ "unicode", "ascii" }) do
      render.last_error = nil
      local result = render.render(ir, { width = width, charset = charset })
      eq(render.last_error, nil)
      eq(mark_problems(result), {})
    end
  end
end

-- ---------------------------------------------------------------------------------------
-- Gate 3: esquerda, centro e direita
-- ---------------------------------------------------------------------------------------

T["alinhamento do conteúdo"] = new_set()

T["alinhamento do conteúdo"]["esquerda"] = function()
  eq(r("| h |\n|:--|\n| a |\n| longer |").lines, {
    "┌────────┐",
    "│ h      │",
    "├────────┤",
    "│ a      │",
    "│ longer │",
    "└────────┘",
  })
end

T["alinhamento do conteúdo"]["centro: a sobra ímpar fica à direita"] = function()
  eq(r("| h |\n|:-:|\n| a |\n| longer |\n| ab |").lines, {
    "┌────────┐",
    "│   h    │",
    "├────────┤",
    "│   a    │",
    "│ longer │",
    "│   ab   │",
    "└────────┘",
  })
end

T["alinhamento do conteúdo"]["direita"] = function()
  eq(r("| h |\n|--:|\n| a |\n| longer |").lines, {
    "┌────────┐",
    "│      h │",
    "├────────┤",
    "│      a │",
    "│ longer │",
    "└────────┘",
  })
end

T["alinhamento do conteúdo"]["sem marcador no delimitador é esquerda"] = function()
  eq(r("| h |\n|---|\n| a |\n| longer |").lines, r("| h |\n|:--|\n| a |\n| longer |").lines)
end

T["alinhamento do conteúdo"]["cada coluna tem o seu, e o cabeçalho segue a coluna"] = function()
  local result = r("| L | C | R |\n|:--|:-:|--:|\n| a | b | c |\n| esq | meio | dir |")
  eq(result.lines, {
    "┌─────┬──────┬─────┐",
    "│ L   │  C   │   R │",
    "├─────┼──────┼─────┤",
    "│ a   │  b   │   c │",
    "│ esq │ meio │ dir │",
    "└─────┴──────┴─────┘",
  })
end

T["alinhamento do conteúdo"]["largura de display, não bytes: CJK e emoji alinham à direita e ao centro"] = function()
  local result = r("| h | h |\n|--:|:-:|\n| 日本語 | 😀 |\n| a | 日本語 |")
  eq(render.last_error, nil)
  eq(result.lines[4], "│ 日本語 │   😀   │")
  eq(result.lines[5], "│      a │ 日本語 │")
  expect_aligned(result.lines, UNICODE_GLYPHS)
end

-- ---------------------------------------------------------------------------------------
-- Bordas e charset
-- ---------------------------------------------------------------------------------------

T["bordas"] = new_set()

T["bordas"]["unicode: caixa completa com linha de grade depois do cabeçalho"] = function()
  eq(r("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |").lines, {
    "┌───┬───┐",
    "│ a │ b │",
    "├───┼───┤",
    "│ 1 │ 2 │",
    "│ 3 │ 4 │",
    "└───┴───┘",
  })
end

T["bordas"]["ascii: + - |"] = function()
  eq(r("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |", { charset = "ascii" }).lines, {
    "+---+---+",
    "| a | b |",
    "+---+---+",
    "| 1 | 2 |",
    "| 3 | 4 |",
    "+---+---+",
  })
end

T["bordas"]["ascii: nenhum byte acima de 127 nas bordas, nem nas reticências"] = function()
  local doc =
    "| id | descrição |\n|--|--|\n| 1 | uma descrição bem comprida que não cabe na janela estreita |"
  local ascii_doc = doc:gsub("ç", "c"):gsub("ã", "a")
  for _, width in ipairs({ 80, 30, 20 }) do
    local result = r(ascii_doc, { charset = "ascii", width = width })
    eq(render.last_error, nil)
    for _, line in ipairs(result.lines) do
      eq({ line, line:find("[\128-\255]") }, { line })
    end
  end
  -- Com conteúdo não ASCII, as bordas continuam ASCII: tira-se o conteúdo e confere o resto.
  local result = r("| 日本語 | 😀 |\n|--|--|\n| ñ | é |", { charset = "ascii" })
  eq(result.lines[1], "+--------+----+")
  eq(result.lines[3], "+--------+----+")
  eq(result.lines[5], "+--------+----+")
  for _, line in ipairs(result.lines) do
    eq(line:sub(1, 1) == "|" or line:sub(1, 1) == "+", true)
    eq(line:sub(-1) == "|" or line:sub(-1) == "+", true)
  end
end

T["bordas"]["charset auto resolvido pelo dispatcher chega ao módulo já resolvido"] = function()
  local saved = vim.env.TERM
  vim.env.TERM = "dumb"
  local ok, result = pcall(render.render, parse.parse_lines("| a |\n|---|\n| 1 |"), { width = 20 })
  vim.env.TERM = saved
  eq(ok, true)
  eq(result.lines[1], "+---+")
end

T["bordas"]["charset desconhecido cai para ascii em vez de lançar"] = function()
  local lines = require("deckle.render.table").render(
    { kind = "table", header = { text("a") }, rows = {}, align = {} },
    { width = 20, charset = "bogus", indent = 0, depth = 0 }
  )
  eq(lines, { "+---+", "| a |", "+---+" })
end

-- ---------------------------------------------------------------------------------------
-- Tabela mais larga que a janela
-- ---------------------------------------------------------------------------------------

T["truncamento"] = new_set()

local LONG_TABLE = table.concat({
  "| id | descrição | notas |",
  "|--|--|--|",
  "| 1 | uma descrição bastante longa que estoura qualquer janela estreita | 日本語日本語日本語日本語日本語 |",
  "| 22 | curta | 😀😀😀😀😀😀😀😀😀😀 |",
}, "\n")

T["truncamento"]["cabe em ctx.width, em qualquer largura viável, e continua alinhada"] = function()
  for _, charset in ipairs({ "unicode", "ascii" }) do
    -- A menor largura que cabe: moldura (10) mais o piso de cada coluna (as reticências, de
    -- 1 ou 3 células; a coluna `id` tem 2).
    local smallest = charset == "ascii" and 18 or 13
    for width = smallest, 90 do
      local result = r(LONG_TABLE, { width = width, charset = charset })
      eq(render.last_error, nil)
      eq({ width, charset, widest(result.lines) <= width }, { width, charset, true })
      eq(#distinct_widths(result.lines), 1)
      eq(mark_problems(result), {})
      expect_aligned(result.lines, charset == "ascii" and ASCII_GLYPHS or UNICODE_GLYPHS)
    end
  end
end

T["truncamento"]["tabela que cabe não é tocada nem esticada"] = function()
  local natural = r(LONG_TABLE, { width = 200 })
  local width = widest(natural.lines)
  eq(width < 200, true)
  eq(r(LONG_TABLE, { width = width }).lines, natural.lines)
  eq(table.concat(natural.lines, "\n"):find("…"), nil)
  -- Um a menos e já trunca.
  eq(table.concat(r(LONG_TABLE, { width = width - 1 }).lines, "\n"):find("…") ~= nil, true)
end

T["truncamento"]["trunca a coluna mais larga primeiro e deixa as estreitas inteiras"] = function()
  local result =
    r("| id | texto |\n|--|--|\n| 7 | " .. string.rep("palavra ", 10) .. " |", { width = 30 })
  eq(render.last_error, nil)
  eq(widest(result.lines), 30)
  local cells_ = row_cells(result.lines[4], "│")
  eq(cells_[1], "7")
  eq(cells_[2]:sub(-#"…") == "…", true)
  -- O cabeçalho cabia e fica inteiro.
  eq(row_cells(result.lines[2], "│"), { "id", "texto" })
end

T["truncamento"]["repete até caber: colunas igualmente largas são niveladas"] = function()
  local a, b, c = string.rep("a", 20), string.rep("b", 20), string.rep("c", 20)
  local result = r("| " .. a .. " | " .. b .. " | " .. c .. " |\n|--|--|--|", { width = 40 })
  eq(render.last_error, nil)
  -- 40 - 10 de moldura = 30 para três colunas: 10 cada, todas truncadas.
  eq(result.lines[2], "│ aaaaaaaaa… │ bbbbbbbbb… │ ccccccccc… │")
  eq(cells(result.lines[2]), 40)
end

T["truncamento"]["a sobra de uma divisão inexata vai para as colunas da esquerda"] = function()
  local a, b, c = string.rep("a", 20), string.rep("b", 20), string.rep("c", 20)
  local result = r("| " .. a .. " | " .. b .. " | " .. c .. " |\n|--|--|--|", { width = 41 })
  -- 31 para três colunas: 11, 10, 10.
  eq(result.lines[2], "│ aaaaaaaaaa… │ bbbbbbbbb… │ ccccccccc… │")
  eq(cells(result.lines[2]), 41)
end

T["truncamento"]["reticências: … em unicode e ... em ascii"] = function()
  local doc = "| h |\n|--|\n| " .. string.rep("x", 30) .. " |"
  eq(r(doc, { width = 14 }).lines[4], "│ xxxxxxxxx… │")
  eq(r(doc, { width = 14, charset = "ascii" }).lines[4], "| xxxxxxx... |")
end

T["truncamento"]["coluna nunca encolhe abaixo das reticências, e uma já curta fica como está"] = function()
  local result = r("| a | " .. string.rep("b", 20) .. " |\n|--|--|", { width = 14 })
  eq(render.last_error, nil)
  eq(result.lines[2], "│ a │ bbbbb… │")
  -- Janela mínima (10): sobram 3 células para o conteúdo, uma para `a` e duas para a outra.
  local tight = r("| a | " .. string.rep("b", 20) .. " |\n|--|--|", { width = 10 })
  eq(tight.lines[2], "│ a │ b… │")
  eq(cells(tight.lines[2]), 10)
  -- Menos que isso, cada coluna fica no piso (as reticências) e a tabela transborda.
  local three = r("| a | b | " .. string.rep("c", 20) .. " |\n|--|--|--|", { width = 10 })
  eq(three.lines[2], "│ a │ b │ … │")
end

T["truncamento"]["nunca parte um caractere largo: CJK e emoji cortam entre caracteres"] = function()
  local cjk = "日本語日本語日本語"
  local emoji = "😀😀😀😀😀😀"
  local family = "👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧"
  for _, original in ipairs({ cjk, emoji, family }) do
    for width = 12, 34 do
      local result = r("| h | h |\n|--|--|\n| x | " .. original .. " |", { width = width })
      eq(render.last_error, nil)
      eq(#distinct_widths(result.lines), 1)
      eq(widest(result.lines) <= width, true)
      expect_aligned(result.lines, UNICODE_GLYPHS)

      local cell = row_cells(result.lines[4], "│")[2]
      if cell ~= original then
        -- Terminou nas reticências e o que sobrou é um prefixo inteiro do original: nenhum
        -- caractere ficou pela metade, nenhuma sequência ZWJ foi desfeita.
        eq(cell:sub(-#"…") == "…", true)
        local prefix = cell:sub(1, #cell - #"…")
        local original_clusters = vim.fn.split(original, "\\zs")
        local kept = vim.fn.split(prefix, "\\zs")
        eq({ width, vim.list_slice(original_clusters, 1, #kept) }, { width, kept })
      end
    end
  end
end

T["truncamento"]["emoji que não cabe no último espaço deixa a coluna com padding, sem estourar"] = function()
  -- Coluna de 6 células: 5 para o texto + `…`; o terceiro emoji (de 2) não cabe no que sobra
  -- (1), então a célula fica com uma de padding a mais.
  local result = r("| h | h |\n|--|--|\n| x | 😀😀😀😀😀😀 |", { width = 14 })
  eq(result.lines[4], "│ x │ 😀😀…  │")
  eq(cells(result.lines[4]), cells(result.lines[1]))
  expect_aligned(result.lines, UNICODE_GLYPHS)
end

T["truncamento"]["dentro de um quote a tabela cabe no que sobra da largura"] = function()
  local result =
    r("> | a | b |\n> |---|---|\n> | " .. string.rep("x", 40) .. " | y |", { width = 24 })
  eq(render.last_error, nil)
  eq(widest(result.lines) <= 24, true)
  eq(#distinct_widths(result.lines), 1)
  eq(mark_problems(result), {})
  for _, line in ipairs(result.lines) do
    eq(vim.startswith(line, "│ "), true)
  end
end

-- ---------------------------------------------------------------------------------------
-- Spans inline e marcas
-- ---------------------------------------------------------------------------------------

T["marcas"] = new_set()

local STYLED = table.concat({
  "| nome | valor |",
  "|:-----|------:|",
  "| 日本語 | **negrito** |",
  "| 😀 | `código` |",
  "| [link](http://x) | *it* |",
  "| **a** *b* | [**x**](u) |",
}, "\n")

T["marcas"]["cada estilo marca o texto certo depois do recuo e do padding"] = function()
  local result = r(STYLED)
  eq(render.last_error, nil)
  eq(mark_problems(result), {})
  eq(marked(result, "DeckleStrong"), { "negrito", "a", "x" })
  eq(marked(result, "DeckleCodeInline"), { "código" })
  eq(marked(result, "DeckleEmphasis"), { "it", "b" })
  eq(marked(result, "DeckleLink"), { "link", "x" })
end

T["marcas"]["a marca de uma célula alinhada à direita começa no texto, não no recuo"] = function()
  local result = r("| h |\n|--:|\n| a |\n| **negrito longo** |\n| `c` |")
  eq(result.lines[4], "│             a │")
  eq(marked(result, "DeckleStrong"), { "negrito longo" })
  eq(marked(result, "DeckleCodeInline"), { "c" })
  local mark = vim.tbl_filter(function(m)
    return m.hl == "DeckleCodeInline"
  end, result.marks)[1]
  eq(result.lines[mark.row + 1]:sub(mark.col + 1, mark.end_col), "c")
  -- A borda (1), o recuo do alinhamento e o padding: o texto começa na célula 14, não na 2.
  eq(cells(result.lines[mark.row + 1]:sub(1, mark.col)), 14)
end

T["marcas"]["as marcas seguem o texto quando antes dele há CJK e emoji"] = function()
  local result = r("| 日本語 | 😀 | x |\n|---|---|---|\n| 日本語 | 😀 | **fim** |")
  eq(marked(result, "DeckleStrong"), { "fim" })
  eq(mark_problems(result), {})
end

T["marcas"]["truncar cortando um trecho estilizado mantém a marca, e ela cobre as reticências"] = function()
  local result =
    r("| h |\n|--|\n| **" .. string.rep("negrito ", 5) .. "negrito** |", { width = 20 })
  eq(render.last_error, nil)
  eq(mark_problems(result), {})
  local strong = marked(result, "DeckleStrong")
  eq(#strong, 1)
  eq(strong[1]:sub(-#"…") == "…", true)
  eq(vim.startswith(strong[1], "negrito"), true)
end

T["marcas"]["truncar antes de um trecho estilizado descarta a marca em vez de apontar para fora"] = function()
  local result = r("| h |\n|--|\n| " .. string.rep("x", 30) .. " **negrito** |", { width = 20 })
  eq(render.last_error, nil)
  eq(mark_problems(result), {})
  eq(marked(result, "DeckleStrong"), {})
end

T["marcas"]["truncar um trecho estilizado com CJK não parte o caractere"] = function()
  for width = 14, 30 do
    local result =
      r("| h |\n|--|\n| **日本語日本語日本語日本語** texto |", { width = width })
    eq(render.last_error, nil)
    eq({ width, mark_problems(result) }, { width, {} })
  end
end

T["marcas"]["DeckleTableBorder cobre só glifos de borda: uma marca por linha de grade e por barra"] = function()
  local result = r("| a | b |\n|---|---|\n| 1 | 2 |")
  eq(marked(result, "DeckleTableBorder"), {
    "┌───┬───┐",
    "│",
    "│",
    "│",
    "├───┼───┤",
    "│",
    "│",
    "│",
    "└───┴───┘",
  })
  local ascii = r("| a | b |\n|---|---|\n| 1 | 2 |", { charset = "ascii" })
  for _, glyphs in ipairs(marked(ascii, "DeckleTableBorder")) do
    eq(glyphs:find("[^|+%-]"), nil)
  end
end

T["marcas"]["DeckleTableHeader cobre cada célula do cabeçalho, e só ela"] = function()
  local result = r("| a | 日本語 | **c** |\n|---|---|---|\n| 1 | 2 | 3 |")
  eq(render.last_error, nil)
  local covered = marked(result, "DeckleTableHeader")
  eq(#covered, 3)
  eq(
    vim.tbl_map(function(s)
      return vim.trim(s)
    end, covered),
    { "a", "日本語", "c" }
  )
  for _, mark in ipairs(result.marks) do
    if mark.hl == "DeckleTableHeader" then
      -- Linha 1 (a 0 é a borda de cima).
      eq(mark.row, 1)
      -- Abaixo da prioridade padrão do extmark (4096), onde ficam as marcas inline.
      eq(mark.priority < 4096, true)
    end
  end
  eq(marked(result, "DeckleStrong"), { "c" })
end

T["marcas"]["sem cabeçalho não há marca de cabeçalho"] = function()
  local result = render_block({ rows = { { text("a") } } })
  eq(marked(result, "DeckleTableHeader"), {})
end

T["marcas"]["as marcas de uma tabela dentro de um quote deslocam junto com o prefixo"] = function()
  local result = r("> | a | **b** |\n> |---|---|\n> | 1 | 2 |")
  eq(render.last_error, nil)
  eq(mark_problems(result), {})
  eq(marked(result, "DeckleStrong"), { "b" })
  eq(#marked(result, "DeckleTableHeader"), 2)
end

-- ---------------------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------------------

T["highlights"] = new_set()

T["highlights"]["os grupos da tabela existem, linkados e com default"] = function()
  local groups = require("deckle.highlight").groups
  eq(groups.DeckleTableHeader, { link = "Title" })
  eq(groups.DeckleTableBorder, { link = "Comment" })

  vim.api.nvim_set_hl(0, "DeckleTableHeader", { fg = 0x00ff00 })
  local saved = vim.api.nvim_get_hl(0, { name = "DeckleTableHeader" })
  require("deckle.highlight").setup()
  -- `default = true`: o grupo que o usuário definiu antes vence.
  eq(vim.api.nvim_get_hl(0, { name = "DeckleTableHeader" }), saved)
  eq(vim.api.nvim_get_hl(0, { name = "DeckleTableBorder" }).link, "Comment")
end

T["highlights"]["todo hl que a tabela escreve existe em deckle.highlight"] = function()
  local defined = require("deckle.highlight").groups
  local result = r(STYLED)
  local seen = {}
  for _, mark in ipairs(result.marks) do
    seen[mark.hl] = true
  end
  eq(seen.DeckleTableHeader, true)
  eq(seen.DeckleTableBorder, true)
  for name in pairs(seen) do
    eq({ name, defined[name] ~= nil }, { name, true })
  end
end

return T
