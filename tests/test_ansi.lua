-- Testes de `deckle.render.ansi`: o parser de escapes SGR do Mermaid colorido.
--
-- Três frentes: casos sintéticos (um por código SGR, mais os escapes que não são SGR e os
-- truncados), fixtures reais do merman 0.10.0 (`tests/fixtures/ansi/`: a saída TrueColor, Ansi256 e
-- Ansi16 de diagramas com `classDef`, `style`, `linkStyle`, `box rgb` e `rect rgb`, cada uma com a
-- saída Plain do mesmo fonte ao lado) e os grupos de highlight, que mexem em estado global do
-- Neovim e por isso rodam num Neovim filho.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local ansi = require("deckle.render.ansi")

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h")
local fixtures = tests_dir .. "/fixtures/ansi/"

local ESC = "\27"
local PREFIX = "DeckleMermaidC_"

---@param name string
---@return string[]
local function fixture(name)
  return vim.fn.readfile(fixtures .. name)
end

--- Nomes de grupo, na ordem em que aparecem, sem repetir.
---@param marks table[]
---@return string[]
local function names(marks)
  local seen, out = {}, {}
  for _, mark in ipairs(marks) do
    if not seen[mark.hl] then
      seen[mark.hl] = true
      out[#out + 1] = mark.hl
    end
  end
  return out
end

--- O texto que uma marca cobre em `clean`.
---@param clean string[]
---@param mark table
---@return string
local function covered(clean, mark)
  return clean[mark.row + 1]:sub(mark.col + 1, mark.end_col)
end

--- Grupo da marca que cobre exatamente `text` (a primeira que achar), ou `nil`.
---@param clean string[]
---@param marks table[]
---@param text string
---@return string|nil
local function group_of(clean, marks, text)
  for _, mark in ipairs(marks) do
    if covered(clean, mark) == text then
      return mark.hl
    end
  end
  return nil
end

---@param s string
---@param pos integer  1-indexado
---@return boolean
local function is_continuation(s, pos)
  local byte = s:byte(pos)
  return byte ~= nil and byte >= 0x80 and byte <= 0xBF
end

--- Invariantes de toda saída de `parse`: marcas dentro da linha, em ordem, sem sobreposição,
--- nunca vazias, nem partidas no meio de um caractere UTF-8, e fundidas quando vizinhas do mesmo
--- grupo. Devolve a primeira violação.
---@param clean string[]
---@param marks table[]
---@return string|nil
local function violation(clean, marks)
  local previous
  for _, mark in ipairs(marks) do
    local line = clean[mark.row + 1]
    if not line then
      return "marca numa linha que não existe: " .. vim.inspect(mark)
    end
    if not (mark.col >= 0 and mark.col < mark.end_col and mark.end_col <= #line) then
      return "intervalo fora da linha: " .. vim.inspect(mark)
    end
    if is_continuation(line, mark.col + 1) or is_continuation(line, mark.end_col + 1) then
      return "marca no meio de um caractere: " .. vim.inspect(mark)
    end
    if mark.hl:sub(1, #PREFIX) ~= PREFIX then
      return "grupo com nome estranho: " .. mark.hl
    end
    if previous and previous.row == mark.row then
      if mark.col < previous.end_col then
        return "marcas sobrepostas: " .. vim.inspect({ previous, mark })
      end
      if mark.col == previous.end_col and mark.hl == previous.hl then
        return "marcas vizinhas do mesmo grupo sem fundir: " .. vim.inspect({ previous, mark })
      end
    elseif previous and mark.row < previous.row then
      return "marcas fora de ordem: " .. vim.inspect({ previous, mark })
    end
    previous = mark
  end
  return nil
end

local T = new_set()

-- ---------------------------------------------------------------------------------------
-- Sem escape
-- ---------------------------------------------------------------------------------------

T["sem escape"] = new_set()

T["sem escape"]["o texto passa igual, numa tabela nova, e não há marca"] = function()
  local lines = { "um", "", "┌─┐ 日本語 😀" }
  local clean, marks = ansi.parse(lines)
  eq(clean, lines)
  eq(marks, {})
  eq(rawequal(clean, lines), false)
end

T["sem escape"]["entrada vazia"] = function()
  local clean, marks = ansi.parse({})
  eq(clean, {})
  eq(marks, {})
end

T["sem escape"]["`has_escapes`"] = function()
  eq(ansi.has_escapes({}), false)
  eq(ansi.has_escapes({ "a", "┌─┐", "" }), false)
  eq(ansi.has_escapes({ "a", ESC .. "[0m" }), true)
  eq(ansi.has_escapes({ ESC }), true)
end

-- ---------------------------------------------------------------------------------------
-- Um caso por código SGR
-- ---------------------------------------------------------------------------------------

T["sgr"] = new_set()

--- `ESC [ <params> m`, o texto `x` e um reset.
---@param params string
---@return string
local function styled(params)
  return ESC .. "[" .. params .. "mx" .. ESC .. "[0m"
end

---@param params string
---@return string|nil  o grupo da marca que `x` ganha, ou `nil` se ficou sem estilo
local function group_for(params)
  local clean, marks = ansi.parse({ styled(params) })
  eq(clean, { "x" })
  eq(violation(clean, marks), nil)
  eq(#marks <= 1, true)
  return marks[1] and marks[1].hl or nil
end

T["sgr"]["as 16 cores: 30-37 e 90-97 na frente, 40-47 e 100-107 no fundo"] = function()
  for n = 0, 7 do
    eq(group_for(tostring(30 + n)), PREFIX .. "a" .. n .. "_")
    eq(group_for(tostring(90 + n)), PREFIX .. "a" .. (n + 8) .. "_")
    eq(group_for(tostring(40 + n)), PREFIX .. "_a" .. n)
    eq(group_for(tostring(100 + n)), PREFIX .. "_a" .. (n + 8))
  end
end

T["sgr"]["`38;5;n` e `48;5;n`: as 16 primeiras seguem o esquema, o resto vira RGB"] = function()
  eq(group_for("38;5;1"), PREFIX .. "a1_")
  eq(group_for("38;5;15"), PREFIX .. "a15_")
  eq(group_for("38;5;16"), PREFIX .. "000000_") -- primeiro do cubo
  eq(group_for("38;5;196"), PREFIX .. "ff0000_") -- 16 + 36*5
  eq(group_for("48;5;208"), PREFIX .. "_ff8700") -- (5, 2, 0)
  eq(group_for("38;5;231"), PREFIX .. "ffffff_") -- último do cubo
  eq(group_for("38;5;232"), PREFIX .. "080808_") -- primeiro cinza
  eq(group_for("48;5;255"), PREFIX .. "_eeeeee") -- último cinza
end

T["sgr"]["`38;2;r;g;b` e `48;2;r;g;b`"] = function()
  eq(group_for("38;2;255;136;0"), PREFIX .. "ff8800_")
  eq(group_for("48;2;30;30;46"), PREFIX .. "_1e1e2e")
  eq(group_for("38;2;0;0;0"), PREFIX .. "000000_")
  -- Um hexadecimal que começa com `a` não se confunde com `aN`.
  eq(group_for("38;2;170;187;204"), PREFIX .. "aabbcc_")
end

T["sgr"]["vários parâmetros num escape só"] = function()
  eq(group_for("1;38;2;255;136;0;48;2;30;30;46"), PREFIX .. "ff8800_1e1e2e_b")
  eq(group_for("38;5;196;48;5;21"), PREFIX .. "ff0000_0000ff")
  eq(group_for("31;42"), PREFIX .. "a1_a2")
  eq(group_for("1;3;4"), PREFIX .. "__biu")
end

T["sgr"]["atributos: 1, 3, 4, 7 e 9, e os que os desligam: 22, 23, 24, 27 e 29"] = function()
  eq(group_for("1"), PREFIX .. "__b")
  eq(group_for("3"), PREFIX .. "__i")
  eq(group_for("4"), PREFIX .. "__u")
  eq(group_for("7"), PREFIX .. "__r")
  eq(group_for("9"), PREFIX .. "__s")
  eq(group_for("1;3;4;7;9"), PREFIX .. "__biurs")
  eq(group_for("1;22"), nil)
  eq(group_for("3;23"), nil)
  eq(group_for("4;24"), nil)
  eq(group_for("7;27"), nil)
  eq(group_for("9;29"), nil)
  eq(group_for("1;3;22"), PREFIX .. "__i")
end

T["sgr"]["`0` e o escape vazio zeram tudo"] = function()
  eq(group_for("1;31;42;0"), nil)
  eq(group_for("1;31;42;"), nil)
  eq(group_for(""), nil)
  eq(group_for("0"), nil)
  eq(group_for("00"), nil)
  eq(group_for("31;0;44"), PREFIX .. "_a4")
end

T["sgr"]["`39` e `49` voltam só a frente e só o fundo ao padrão"] = function()
  eq(group_for("31;42;39"), PREFIX .. "_a2")
  eq(group_for("31;42;49"), PREFIX .. "a1_")
  eq(group_for("31;49"), PREFIX .. "a1_")
  eq(group_for("38;2;1;2;3;39"), nil)
  eq(group_for("1;39"), PREFIX .. "__b")
end

T["sgr"]["a forma com dois-pontos: `38:5:n`, `38:2:r:g:b`, `38:2::r:g:b`, `4:3`"] = function()
  eq(group_for("38:5:196"), PREFIX .. "ff0000_")
  eq(group_for("48:5:21"), PREFIX .. "_0000ff")
  eq(group_for("38:2:255:136:0"), PREFIX .. "ff8800_")
  eq(group_for("38:2::255:136:0"), PREFIX .. "ff8800_")
  eq(group_for("48:2::30:30:46"), PREFIX .. "_1e1e2e")
  eq(group_for("4:3"), PREFIX .. "__u")
  eq(group_for("4:0"), nil)
  eq(group_for("1;38:2::1:2:3;3"), PREFIX .. "010203__bi")
end

T["sgr"]["o que não se entende não estraga o resto"] = function()
  -- 2 (fraco), 5 (pisca), 53 (sobrelinha): ignorados, o negrito continua.
  eq(group_for("1;2;5;53"), PREFIX .. "__b")
  -- `58` (cor do sublinhado) consome os seus parâmetros sem pintar nada.
  eq(group_for("58;2;1;2;3;1"), PREFIX .. "__b")
  eq(group_for("58;5;9;1"), PREFIX .. "__b")
  -- Cores truncadas ou fora de 0..255 não mudam a cor.
  eq(group_for("1;38;2;1;2"), PREFIX .. "__b")
  eq(group_for("1;38;2;256;0;0"), PREFIX .. "__b")
  eq(group_for("1;38;5"), PREFIX .. "__b")
  eq(group_for("1;38;5;256"), PREFIX .. "__b")
  eq(group_for("1;38;9"), PREFIX .. "__b")
  eq(group_for("1;48"), PREFIX .. "__b")
end

T["sgr"]["o grupo é o mesmo para o mesmo estilo, e os atributos entram em ordem fixa"] = function()
  local _, a = ansi.parse({ ESC .. "[1;3mx" })
  local _, b = ansi.parse({ ESC .. "[3;1mx" })
  local _, c = ansi.parse({ ESC .. "[1m" .. ESC .. "[3mx" })
  eq(a[1].hl, PREFIX .. "__bi")
  eq(b[1].hl, a[1].hl)
  eq(c[1].hl, a[1].hl)
end

-- ---------------------------------------------------------------------------------------
-- Marcas: posição, fusão, estado entre linhas
-- ---------------------------------------------------------------------------------------

T["marcas"] = new_set()

T["marcas"]["intervalo em bytes, 0-indexado, fim exclusivo, medido no texto limpo"] = function()
  local clean, marks = ansi.parse({ "ab" .. ESC .. "[31mcde" .. ESC .. "[0mfg" })
  eq(clean, { "abcdefg" })
  eq(marks, { { row = 0, col = 2, end_col = 5, hl = PREFIX .. "a1_" } })
end

T["marcas"]["texto sem estilo não gera marca, nem o que vem depois do reset"] = function()
  local clean, marks = ansi.parse({ "a" .. ESC .. "[1mb" .. ESC .. "[0mc" .. ESC .. "[mд" })
  eq(clean, { "abcд" })
  eq(marks, { { row = 0, col = 1, end_col = 2, hl = PREFIX .. "__b" } })
end

T["marcas"]["escape sem texto depois dele não gera marca"] = function()
  local clean, marks = ansi.parse({ ESC .. "[31m" .. ESC .. "[0m", ESC .. "[1m", "" })
  eq(clean, { "", "", "" })
  eq(marks, {})
end

T["marcas"]["vizinhas do mesmo grupo se fundem, mesmo com escapes no meio"] = function()
  local clean, marks = ansi.parse({
    ESC .. "[31mab" .. ESC .. "[0m" .. ESC .. "[31mcd" .. ESC .. "[31mef" .. ESC .. "[0m",
  })
  eq(clean, { "abcdef" })
  eq(marks, { { row = 0, col = 0, end_col = 6, hl = PREFIX .. "a1_" } })
end

T["marcas"]["grupos diferentes ficam separados, e o texto liso entre dois iguais os separa"] = function()
  local _, marks = ansi.parse({
    ESC .. "[31mab" .. ESC .. "[32mcd" .. ESC .. "[0m--" .. ESC .. "[32mef" .. ESC .. "[0m",
  })
  eq(marks, {
    { row = 0, col = 0, end_col = 2, hl = PREFIX .. "a1_" },
    { row = 0, col = 2, end_col = 4, hl = PREFIX .. "a2_" },
    { row = 0, col = 6, end_col = 8, hl = PREFIX .. "a2_" },
  })
end

T["marcas"]["o estilo atravessa o fim da linha, até um reset"] = function()
  local clean, marks = ansi.parse({
    "a" .. ESC .. "[1;31mb",
    "cd",
    "",
    "ef" .. ESC .. "[0mg",
    "h",
  })
  eq(clean, { "ab", "cd", "", "efg", "h" })
  eq(marks, {
    { row = 0, col = 1, end_col = 2, hl = PREFIX .. "a1__b" },
    { row = 1, col = 0, end_col = 2, hl = PREFIX .. "a1__b" },
    { row = 3, col = 0, end_col = 2, hl = PREFIX .. "a1__b" },
  })
end

T["marcas"]["o estado começa liso a cada chamada"] = function()
  ansi.parse({ ESC .. "[31mx" })
  local clean, marks = ansi.parse({ "y" })
  eq(clean, { "y" })
  eq(marks, {})
end

T["marcas"]["UTF-8 multibyte: caixa, emoji e CJK em bytes, não em células"] = function()
  local clean, marks = ansi.parse({
    ESC
      .. "[31m┌─┐"
      .. ESC
      .. "[0m 😀 "
      .. ESC
      .. "[32m日本語"
      .. ESC
      .. "[0m é"
      .. ESC
      .. "[34mç",
  })
  eq(clean, { "┌─┐ 😀 日本語 éç" })
  eq(marks, {
    { row = 0, col = 0, end_col = 9, hl = PREFIX .. "a1_" }, -- 3 caracteres de 3 bytes
    { row = 0, col = 9 + 1 + 4 + 1, end_col = 9 + 1 + 4 + 1 + 9, hl = PREFIX .. "a2_" },
    {
      row = 0,
      col = 9 + 1 + 4 + 1 + 9 + 1 + 2,
      end_col = 9 + 1 + 4 + 1 + 9 + 1 + 4,
      hl = PREFIX .. "a4_",
    },
  })
  eq(covered(clean, marks[1]), "┌─┐")
  eq(covered(clean, marks[2]), "日本語")
  eq(covered(clean, marks[3]), "ç")
end

T["marcas"]["um emoji ZWJ e um com tom de pele são um trecho só"] = function()
  local text = "👨‍👩‍👧 👍🏽"
  local clean, marks = ansi.parse({ ESC .. "[33m" .. text .. ESC .. "[0m!" })
  eq(clean, { text .. "!" })
  eq(marks, { { row = 0, col = 0, end_col = #text, hl = PREFIX .. "a3_" } })
end

T["marcas"]["as marcas valem como extmarks de verdade, no texto limpo"] = function()
  local clean, marks = ansi.parse({
    ESC .. "[38;2;255;136;0;48;2;30;30;46m┌─ 日本語 ─┐" .. ESC .. "[0m",
    "│" .. ESC .. "[1m 😀 " .. ESC .. "[0m│",
  })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, clean)
  local ns = vim.api.nvim_create_namespace("deckle_test_ansi")
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark.row, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.hl,
      strict = true,
    })
  end
  local placed = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(#placed, 2)
  eq(placed[1][4].hl_group, PREFIX .. "ff8800_1e1e2e")
  eq(placed[2][4].hl_group, PREFIX .. "__b")
end

-- ---------------------------------------------------------------------------------------
-- O que não é SGR, e o que está quebrado
-- ---------------------------------------------------------------------------------------

T["outros escapes"] = new_set()

---@param input string
---@return string
local function cleaned(input)
  local clean, marks = ansi.parse({ input })
  eq(violation(clean, marks), nil)
  eq(#clean, 1)
  eq(clean[1]:find(ESC, 1, true), nil)
  return clean[1]
end

T["outros escapes"]["CSI com outro final some sem tocar no estilo"] = function()
  eq(cleaned("a" .. ESC .. "[2Kb" .. ESC .. "[1;5Hc" .. ESC .. "[3Ad"), "abcd")
  eq(cleaned("a" .. ESC .. "[?25lb" .. ESC .. "[?1049hc"), "abc")
  eq(cleaned("a" .. ESC .. "[ qb"), "ab") -- com intermediário (DECSCUSR)
  local _, marks = ansi.parse({ ESC .. "[31ma" .. ESC .. "[2Kb" .. ESC .. "[0m" })
  eq(marks, { { row = 0, col = 0, end_col = 2, hl = PREFIX .. "a1_" } })
end

T["outros escapes"]["CSI privado com final `m` não é SGR"] = function()
  local _, marks = ansi.parse({ ESC .. "[>4;2mabc", ESC .. "[?1mdef", ESC .. "[<1mghi" })
  eq(marks, {})
end

T["outros escapes"]["OSC, terminado por BEL ou por ESC \\"] = function()
  eq(cleaned("a" .. ESC .. "]0;titulo" .. "\7" .. "b"), "ab")
  eq(
    cleaned(
      "a" .. ESC .. "]8;;http://x.y" .. ESC .. "\\" .. "b" .. ESC .. "]8;;" .. ESC .. "\\" .. "c"
    ),
    "abc"
  )
  eq(cleaned("a" .. ESC .. "]0;sem fim"), "a")
  -- DCS, SOS, PM e APC são strings de controle como o OSC.
  eq(cleaned("a" .. ESC .. "Pqdados" .. ESC .. "\\b"), "ab")
  eq(cleaned("a" .. ESC .. "_Gi=1;OK" .. ESC .. "\\b"), "ab")
end

T["outros escapes"]["escapes de dois bytes e de charset"] = function()
  eq(cleaned("a" .. ESC .. "7b" .. ESC .. "8c" .. ESC .. "Md" .. ESC .. "=e"), "abcde")
  eq(cleaned("a" .. ESC .. "(Bb" .. ESC .. ")0c"), "abc")
end

T["outros escapes"]["truncado no fim da linha não lança"] = function()
  eq(cleaned("abc" .. ESC), "abc")
  eq(cleaned("abc" .. ESC .. "["), "abc")
  eq(cleaned("abc" .. ESC .. "[3"), "abc")
  eq(cleaned("abc" .. ESC .. "[38;2;1;2"), "abc")
  eq(cleaned("abc" .. ESC .. "[ "), "abc")
  eq(cleaned("abc" .. ESC .. "("), "abc")
  eq(cleaned("abc" .. ESC .. "]0;titulo"), "abc")
  eq(cleaned(ESC), "")
  eq(cleaned(ESC .. ESC .. ESC), "")
  -- O estilo ligado antes do truncamento vale até lá.
  local clean, marks = ansi.parse({ ESC .. "[31mabc" .. ESC .. "[38;2;1" })
  eq(clean, { "abc" })
  eq(marks, { { row = 0, col = 0, end_col = 3, hl = PREFIX .. "a1_" } })
end

T["outros escapes"]["sequência cancelada por outro ESC deixa o resto intacto"] = function()
  local clean, marks = ansi.parse({ "a" .. ESC .. "[38;2;1" .. ESC .. "[31mb" .. ESC .. "[0m" })
  eq(clean, { "ab" })
  eq(marks, { { row = 0, col = 1, end_col = 2, hl = PREFIX .. "a1_" } })
  eq(cleaned("a" .. ESC .. "[" .. "\1" .. "b"), "a" .. "\1" .. "b")
  eq(cleaned("a" .. ESC .. "\1b"), "a" .. "\1b")
end

--- Gerador congruencial, como o de `tests/helpers.lua`: independe de `math.random`.
---@param seed integer
---@return fun(n: integer): integer
local function rng(seed)
  local state = seed
  return function(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return (math.floor(state / 65536) % n) + 1
  end
end

T["outros escapes"]["entrada aleatória: nunca lança, nunca sobra ESC, as marcas são válidas"] = function()
  local pieces = {
    ESC,
    ESC,
    ESC .. "[",
    ESC .. "[",
    ESC .. "]",
    ESC .. "(",
    ESC .. "\\",
    "[",
    "]",
    ";",
    ":",
    "?",
    "m",
    "m",
    "K",
    "H",
    "0",
    "1",
    "3",
    "4",
    "7",
    "9",
    "22",
    "31",
    "38",
    "48",
    "2",
    "5",
    "255",
    "x",
    "yz",
    "é",
    "日",
    "😀",
    "┌",
    "\7",
    " ",
    "\1",
    "<",
    ">",
  }
  local next_int = rng(20260518)
  for case = 1, 4000 do
    local lines = {}
    for l = 1, next_int(4) do
      local parts = {}
      for p = 1, next_int(40) do
        parts[p] = pieces[next_int(#pieces)]
      end
      lines[l] = table.concat(parts)
    end
    local ok, clean, marks = pcall(ansi.parse, lines)
    local where = ("caso %d: %s"):format(case, vim.inspect(lines))
    eq({ where, ok }, { where, true })
    eq({ where, #clean }, { where, #lines })
    for index, line in ipairs(clean) do
      eq({ where, line:find(ESC, 1, true) }, { where })
      eq({ where, #line <= #lines[index] }, { where, true })
    end
    eq({ where, violation(clean, marks) }, { where })
  end
end

-- ---------------------------------------------------------------------------------------
-- A saída real do merman 0.10.0
-- ---------------------------------------------------------------------------------------
--
-- `tests/fixtures/ansi/<nome>.mmd` é o fonte; `<nome>.plain.txt` o que o merman desenha sem cor e
-- `<nome>.truecolor.txt` (`flowchart` também em `.ansi256` e `.ansi16`) com cor. Os `.txt` saem do
-- `merman-ascii` 0.10.0 (`AsciiRenderOptions::unicode().with_color_mode(...)`, largura 120), tema
-- padrão. `cicd` e `sequence` são cortes de `examples/mermaid.md` (o pipeline de CI/CD do
-- flowchart e o diagrama de sequência, com `classDef`, `style`, `linkStyle`, `box` e `rect rgb`);
-- `flowchart` e `unicode` são diagramas pequenos com cores conhecidas, o segundo com emoji e CJK.

T["merman"] = new_set()

local DIAGRAMS = { "flowchart", "sequence", "unicode", "cicd" }

T["merman"]["o texto limpo do TrueColor é, byte a byte, a saída Plain"] = function()
  for _, name in ipairs(DIAGRAMS) do
    local colored = fixture(name .. ".truecolor.txt")
    local plain = fixture(name .. ".plain.txt")
    eq({ name, ansi.has_escapes(colored) }, { name, true })
    eq({ name, ansi.has_escapes(plain) }, { name, false })
    local clean = ansi.parse(colored)
    eq({ name, clean }, { name, plain })
    eq({ name, table.concat(clean, "\n") }, { name, table.concat(plain, "\n") })
  end
end

T["merman"]["Ansi256 e Ansi16 também limpam para a saída Plain"] = function()
  local plain = fixture("flowchart.plain.txt")
  for _, mode in ipairs({ "ansi256", "ansi16" }) do
    local colored = fixture("flowchart." .. mode .. ".txt")
    eq({ mode, ansi.has_escapes(colored) }, { mode, true })
    local clean, marks = ansi.parse(colored)
    eq({ mode, clean }, { mode, plain })
    eq({ mode, violation(clean, marks) }, { mode })
    eq({ mode, #marks > 0 }, { mode, true })
  end
end

T["merman"]["nenhum ESC sobra, e as marcas são válidas, em bytes, nos três diagramas"] = function()
  for _, name in ipairs(DIAGRAMS) do
    local clean, marks = ansi.parse(fixture(name .. ".truecolor.txt"))
    for _, line in ipairs(clean) do
      eq({ name, line:find(ESC, 1, true) }, { name })
    end
    eq({ name, violation(clean, marks) }, { name })
    eq({ name, #marks > 0 }, { name, true })
  end
end

T["merman"]["cada linha termina lisa: nenhuma depende da anterior"] = function()
  -- O merman fecha todo trecho com `ESC [ 0 m`, inclusive no fim da linha. Se alguma linha
  -- deixasse o estilo aberto, `parse` de todas juntas diferiria de `parse` de cada uma.
  for _, name in ipairs(DIAGRAMS) do
    local lines = fixture(name .. ".truecolor.txt")
    local _, whole = ansi.parse(lines)
    local by_line = {}
    for index, line in ipairs(lines) do
      local _, marks = ansi.parse({ line })
      for _, mark in ipairs(marks) do
        mark.row = index - 1
        by_line[#by_line + 1] = mark
      end
    end
    eq({ name, whole }, { name, by_line })
    for index, line in ipairs(lines) do
      -- O último escape de toda linha é o reset (depois dele pode vir só espaço liso).
      local last_sgr = line:match(".*(\27%[[%d;]*m)")
      eq({ name, index, last_sgr }, { name, index, last_sgr and ESC .. "[0m" })
    end
  end
end

T["merman"]["flowchart: as cores do classDef, do style e do linkStyle"] = function()
  local clean, marks = ansi.parse(fixture("flowchart.truecolor.txt"))
  local seen = {}
  for _, name in ipairs(names(marks)) do
    seen[name] = true
  end

  -- `classDef ok fill:#ff8800,stroke:#1e1e2e,color:#1e1e2e`: borda em 1e1e2e sobre o fundo.
  eq(seen[PREFIX .. "1e1e2e_ff8800"], true)
  eq(seen[PREFIX .. "_ff8800"], true)
  -- `classDef err fill:#cc3333,stroke:#ffffff,color:#ffffff`.
  eq(seen[PREFIX .. "ffffff_cc3333"], true)
  eq(seen[PREFIX .. "_cc3333"], true)
  -- `style C fill:#0088ff,stroke:#003366,color:#ffffff`.
  eq(seen[PREFIX .. "003366_0088ff"], true)
  eq(seen[PREFIX .. "_0088ff"], true)
  -- `linkStyle 1 stroke:#00ff88` e `linkStyle 2 stroke:#ff3366`: só a frente.
  eq(seen[PREFIX .. "00ff88_"], true)
  eq(seen[PREFIX .. "ff3366_"], true)

  -- Os rótulos, em UTF-8 (`í`, `á`, `ã` têm dois bytes), com a `color` do nó. O merman só põe o
  -- fundo nas células de preenchimento: o glifo do rótulo leva a frente e não o fundo.
  eq(group_of(clean, marks, "Início"), PREFIX .. "1e1e2e_")
  eq(group_of(clean, marks, "Salvar"), PREFIX .. "ffffff_")
  eq(group_of(clean, marks, "Erro"), PREFIX .. "ffffff_")
  -- Sem estilo próprio, o tema padrão pinta o texto com a cor `Text` (#27272a).
  eq(group_of(clean, marks, "Válido?"), PREFIX .. "27272a_")
  eq(group_of(clean, marks, "sim"), PREFIX .. "27272a_")
  eq(group_of(clean, marks, "não"), PREFIX .. "27272a_")
end

T["merman"]["flowchart: o rótulo `Início` cai nos bytes certos da linha"] = function()
  local clean, marks = ansi.parse(fixture("flowchart.truecolor.txt"))
  for _, mark in ipairs(marks) do
    if covered(clean, mark) == "Início" then
      local line = clean[mark.row + 1]
      -- `│ Início ├` : 1 caractere de 3 bytes, um espaço, a palavra (7 bytes com o `í`).
      eq(mark.col, #"│ ")
      eq(mark.end_col - mark.col, #"Início")
      eq(#"Início", 7)
      eq(vim.fn.strdisplaywidth(line:sub(1, mark.col)), 2)
      return
    end
  end
  error("a marca de `Início` não apareceu")
end

T["merman"]["unicode: emoji e CJK em bytes certos, com as cores do classDef"] = function()
  local clean, marks = ansi.parse(fixture("unicode.truecolor.txt"))
  eq(violation(clean, marks), nil)
  eq(group_of(clean, marks, "🚀 Lançamento"), PREFIX .. "1e1e2e_") -- classDef rapido
  eq(group_of(clean, marks, "Ação 完了"), PREFIX .. "ffffff_") -- classDef azul
  eq(group_of(clean, marks, "❌ Erro"), PREFIX .. "ffffff_") -- style D
  eq(group_of(clean, marks, "日本語 ok?"), PREFIX .. "27272a_")
  local seen = {}
  for _, name in ipairs(names(marks)) do
    seen[name] = true
  end
  eq(seen[PREFIX .. "_ff8800"], true)
  eq(seen[PREFIX .. "_1e66f5"], true)
  eq(seen[PREFIX .. "_cc3333"], true)
  eq(seen[PREFIX .. "00ff88_"], true) -- linkStyle 0

  -- As marcas valem em bytes: o texto que cobrem, medido em células, é o do rótulo.
  for _, mark in ipairs(marks) do
    local text = covered(clean, mark)
    if text == "日本語 ok?" then
      eq(vim.fn.strdisplaywidth(text), 10)
      eq(#text, 3 * 3 + #" ok?")
    end
  end
end

T["merman"]["sequence: os fundos de `box rgb` e de `rect rgb`"] = function()
  local clean, marks = ansi.parse(fixture("sequence.truecolor.txt"))
  eq(violation(clean, marks), nil)
  local backgrounds = {}
  for _, name in ipairs(names(marks)) do
    local bg = name:match("^" .. PREFIX .. "%x*_(%x+)")
    if bg then
      backgrounds[bg] = true
    end
  end
  eq(backgrounds["e6f0ff"], true) -- box rgb(230, 240, 255) Cliente
  eq(backgrounds["00ffff"], true) -- box Aqua Nativo: o merman resolve o nome CSS
  eq(backgrounds["e6ffe6"], true) -- rect rgb(230, 255, 230)
  eq(backgrounds["f5e6ff"], true) -- rect rgb(245, 230, 255)
  -- O título do `box` é do mesmo fundo do `box`, com a cor `Section` do tema (#7c3aed).
  eq(group_of(clean, marks, " Cliente "), PREFIX .. "7c3aed_e6f0ff")
  eq(group_of(clean, marks, " Nativo "), PREFIX .. "7c3aed_00ffff")
  -- O texto dos participantes e das mensagens leva a cor `Text` (#27272a) sobre o fundo do `box`.
  eq(group_of(clean, marks, "Neovim"), PREFIX .. "27272a_e6f0ff")
  eq(group_of(clean, marks, "deckle (Lua)"), PREFIX .. "27272a_e6f0ff")
end

T["merman"]["cicd: classDef, style e linkStyle do pipeline do examples/mermaid.md"] = function()
  local clean, marks = ansi.parse(fixture("cicd.truecolor.txt"))
  eq(violation(clean, marks), nil)
  local seen = {}
  for _, name in ipairs(names(marks)) do
    seen[name] = true
  end
  -- `classDef ok fill:#d4edda,stroke:#28a745,color:#155724`: borda sobre o fundo, e o fundo só.
  eq(seen[PREFIX .. "28a745_d4edda"], true)
  eq(seen[PREFIX .. "_d4edda"], true)
  -- `classDef warn fill:#fff3cd,stroke:#ffc107,color:#856404`.
  eq(seen[PREFIX .. "ffc107_fff3cd"], true)
  eq(seen[PREFIX .. "_fff3cd"], true)
  -- `classDef cjk fill:#e8eaf6,stroke:#3949ab`.
  eq(seen[PREFIX .. "3949ab_e8eaf6"], true)
  -- `style BUILD fill:#e1f5fe,stroke:#0288d1`.
  eq(seen[PREFIX .. "0288d1_e1f5fe"], true)
  -- `linkStyle 0 stroke:#28a745`, `linkStyle 1,2 stroke:#ff9800`, `linkStyle default stroke:#666`.
  eq(seen[PREFIX .. "28a745_"], true)
  eq(seen[PREFIX .. "ff9800_"], true)
  eq(seen[PREFIX .. "666666_"], true)

  -- O texto leva a `color` do `classDef`, ou a cor `Text` do tema quando o nó não define uma.
  eq(group_of(clean, marks, "Lint"), PREFIX .. "155724_")
  eq(group_of(clean, marks, "E2E"), PREFIX .. "856404_")
  eq(group_of(clean, marks, "Unitários"), PREFIX .. "27272a_")
  -- Os rótulos em japonês e chinês: 3 bytes por caractere, 2 células cada.
  for _, text in ipairs({ "日本語", "中文" }) do
    local found = false
    for _, mark in ipairs(marks) do
      if covered(clean, mark) == text then
        found = true
        eq(mark.end_col - mark.col, #text)
        eq(vim.fn.strdisplaywidth(text), 2 * vim.fn.strchars(text))
      end
    end
    eq({ text, found }, { text, true })
  end
end

T["merman"]["Ansi256: o fundo do classDef cai no cubo de 6x6x6"] = function()
  local clean, marks = ansi.parse(fixture("flowchart.ansi256.txt"))
  -- #ff8800 vira o índice 208, que é (255, 135, 0).
  local seen = {}
  for _, name in ipairs(names(marks)) do
    seen[name] = true
  end
  eq(seen[PREFIX .. "_ff8700"], true)
  eq(violation(clean, marks), nil)
end

T["merman"]["Ansi16: só as cores `aN` do terminal"] = function()
  local _, marks = ansi.parse(fixture("flowchart.ansi16.txt"))
  for _, name in ipairs(names(marks)) do
    local fg, bg = name:match("^" .. PREFIX .. "([%w]*)_([%w]*)$")
    eq({ name, fg ~= nil }, { name, true })
    for _, color in ipairs({ fg, bg }) do
      eq({ name, color == "" or color:match("^a%d+$") ~= nil }, { name, true })
    end
  end
end

-- ---------------------------------------------------------------------------------------
-- Desempenho
-- ---------------------------------------------------------------------------------------

T["desempenho"] = new_set()

T["desempenho"]["2000 linhas de 200 colunas com cores, em menos de 100 ms"] = function()
  local runs = {}
  for c = 1, 20 do
    local fg = ("38;2;%d;%d;%d"):format((c * 37) % 256, (c * 91) % 256, (c * 53) % 256)
    local bg = ("48;2;%d;%d;%d"):format((c * 53) % 256, (c * 91) % 256, (c * 37) % 256)
    runs[c] = ESC .. "[" .. fg .. "m" .. ESC .. "[" .. bg .. "m" .. ("x"):rep(10) .. ESC .. "[0m"
  end
  local line = table.concat(runs)
  local lines = {}
  for i = 1, 2000 do
    lines[i] = line
  end

  -- O melhor de três: o que importa é o custo do parser, não um tropeço do coletor de lixo.
  local best = math.huge
  local clean, marks
  for _ = 1, 3 do
    collectgarbage()
    local started = vim.uv.hrtime()
    clean, marks = ansi.parse(lines)
    best = math.min(best, (vim.uv.hrtime() - started) / 1e6)
  end
  eq(#clean, 2000)
  eq(#clean[1], 200)
  eq(#marks, 2000 * 20)
  eq({ best < 100, best }, { true, best })
end

-- ---------------------------------------------------------------------------------------
-- Grupos de highlight (Neovim filho: mexem em estado global)
-- ---------------------------------------------------------------------------------------

local child = MiniTest.new_child_neovim()

T["grupos"] = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.lua([[
        _G.ansi = require("deckle.render.ansi")
        _G.hl = function(name)
          return vim.api.nvim_get_hl(0, { name = name })
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["grupos"]["o grupo nasce com a frente, o fundo e os atributos do escape"] = function()
  child.lua([[_G.ansi.parse({ "\27[1;38;2;255;136;0;48;2;30;30;46mx\27[0m" })]])
  local hl = child.lua_get([[_G.hl("DeckleMermaidC_ff8800_1e1e2e_b")]])
  eq(hl.fg, 0xff8800)
  eq(hl.bg, 0x1e1e2e)
  eq(hl.bold, true)
  eq(hl.italic, nil)
end

T["grupos"]["itálico, sublinhado, reverso e tachado"] = function()
  child.lua([[_G.ansi.parse({ "\27[3;4;7;9mx\27[0m" })]])
  local hl = child.lua_get([[_G.hl("DeckleMermaidC___iurs")]])
  eq({ hl.italic, hl.underline, hl.reverse, hl.strikethrough }, { true, true, true, true })
  eq(hl.fg, nil)
  eq(hl.bg, nil)
end

T["grupos"]["texto sem estilo não cria grupo nenhum"] = function()
  child.lua([[_G.ansi.parse({ "a", "\27[0mb", "\27[31m\27[0mc" })]])
  eq(
    child.lua_get([[#vim.tbl_filter(function(name)
    return name:find("^DeckleMermaidC_") ~= nil
  end, vim.fn.getcompletion("DeckleMermaidC_", "highlight"))]]),
    0
  )
end

T["grupos"]["as 16 cores seguem `vim.g.terminal_color_N`, e sem ele caem numa paleta xterm"] = function()
  child.lua([[
    vim.g.terminal_color_2 = "#123456"
    _G.ansi.parse({ "\27[32mx\27[0m \27[34my\27[0m \27[1;91mz\27[0m" })
  ]])
  eq(child.lua_get([[_G.hl("DeckleMermaidC_a2_").fg]]), 0x123456)
  eq(child.lua_get([[_G.hl("DeckleMermaidC_a4_").fg]]), 0x0000ee)
  eq(child.lua_get([[_G.hl("DeckleMermaidC_a9__b").fg]]), 0xff0000)
end

T["grupos"]["criar é idempotente: o mesmo grupo, um autocmd só"] = function()
  child.lua([[
    local line = "\27[38;2;255;136;0mx\27[0m"
    _G.ansi.parse({ line })
    _G.first = _G.hl("DeckleMermaidC_ff8800_")
    for _ = 1, 5 do
      _G.ansi.parse({ line })
    end
    _G.ansi.setup()
    _G.ansi.setup()
    _G.ansi.parse({ line })
  ]])
  eq(child.lua_get([[_G.hl("DeckleMermaidC_ff8800_")]]), child.lua_get("_G.first"))
  eq(child.lua_get([[_G.first.fg]]), 0xff8800)
  eq(child.lua_get([[#vim.api.nvim_get_autocmds({ group = "deckle_mermaid_ansi" })]]), 1)
  eq(
    child.lua_get([[vim.api.nvim_get_autocmds({ group = "deckle_mermaid_ansi" })[1].event]]),
    "ColorScheme"
  )
end

T["grupos"]["`:colorscheme` apaga os grupos de `nvim_set_hl`, e o autocmd os refaz"] = function()
  child.lua([[
    -- Um esquema de verdade define a paleta do terminal antes de disparar `ColorScheme`; este
    -- autocmd, criado antes do de `deckle.render.ansi`, faz o mesmo.
    vim.api.nvim_create_autocmd("ColorScheme", {
      callback = function()
        vim.g.terminal_color_1 = "#abcdef"
      end,
    })
    _G.ansi.parse({ "\27[1;38;2;255;136;0;48;2;30;30;46mx\27[0m \27[31my\27[0m" })
  ]])
  eq(child.lua_get([[_G.hl("DeckleMermaidC_a1_").fg]]), 0xcd0000)
  child.cmd("colorscheme default")
  local hl = child.lua_get([[_G.hl("DeckleMermaidC_ff8800_1e1e2e_b")]])
  eq(hl.fg, 0xff8800)
  eq(hl.bg, 0x1e1e2e)
  eq(hl.bold, true)
  -- O refazer relê a paleta: a cor 1 do esquema novo vale.
  eq(child.lua_get([[_G.hl("DeckleMermaidC_a1_").fg]]), 0xabcdef)
  -- E depois do `:colorscheme` `parse` continua criando e reutilizando grupos.
  child.lua([[_G.ansi.parse({ "\27[38;2;1;2;3mz\27[0m" })]])
  eq(child.lua_get([[_G.hl("DeckleMermaidC_010203_").fg]]), 0x010203)
end

T["grupos"]["sem o autocmd, `:colorscheme` apagaria os grupos (o que o autocmd conserta)"] = function()
  child.lua([[
    _G.ansi.parse({ "\27[38;2;255;136;0mx\27[0m" })
    vim.api.nvim_clear_autocmds({ group = "deckle_mermaid_ansi" })
  ]])
  child.cmd("colorscheme default")
  eq(child.lua_get([[_G.hl("DeckleMermaidC_ff8800_")]]), {})
end

return T
