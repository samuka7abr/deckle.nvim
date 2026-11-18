-- Testes de `deckle.render.code` (fase 5): a moldura e o highlight por treesitter.
--
-- Largura é medida com `vim.fn.strdisplaywidth` em todo teste de caixa: emoji, CJK e tab entram
-- junto com a feature (CLAUDE.md, regra 6).
--
-- Todo caminho de degradação (parser ausente, query ausente, erro do treesitter, nome de
-- linguagem inválido) é forçado, não comentado (ADR-0004). O parser de `lua` vem com o
-- Neovim, então o caso colorido roda sem instalar nada; o parser "ausente" é um parser real
-- escondido por stub.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local parse = require("deckle.parse")
local render = require("deckle.render")
local code = require("deckle.render.code")

local T = new_set({
  hooks = {
    pre_case = function()
      code.clear_cache()
      code.stats.parses, code.stats.hits = 0, 0
      code.last_error = nil
      render.last_error = nil
    end,
  },
})

-- ---------------------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------------------

---@param s string
---@return integer
local function cells(s)
  return vim.fn.strdisplaywidth(s)
end

---@param lines string[]
---@return integer[]
local function widths(lines)
  return vim.tbl_map(cells, lines)
end

--- Renderiza `text` (Markdown) na largura 30 e em Unicode, a não ser que `opts` diga outra
--- coisa.
---@param text string
---@param opts table|nil
---@return deckle.RenderResult
local function r(text, opts)
  local merged = vim.tbl_extend("force", { width = 30, charset = "unicode" }, opts or {})
  return render.render(parse.parse_lines(text), merged)
end

--- Um bloco `code` no ctx de topo, direto no módulo (o que a fase 7 faz).
---@param block table
---@param opts table|nil
---@return string[] lines, deckle.Mark[] marks
local function direct(block, opts)
  return code.render(
    block,
    vim.tbl_extend("force", { width = 30, charset = "unicode" }, opts or {})
  )
end

---@param lines string[]
---@param marks deckle.Mark[]
---@param group string|nil o grupo das marcas, ou `@` para todas as de captura (default)
---@return { row: integer, col: integer, hl: string, text: string }[]
local function slices(lines, marks, group)
  group = group or "@"
  local found = {}
  for _, mark in ipairs(marks) do
    if mark.hl == group or (group == "@" and mark.hl:sub(1, 1) == "@") then
      found[#found + 1] = {
        row = mark.row,
        col = mark.col,
        hl = mark.hl,
        text = lines[mark.row + 1]:sub(mark.col + 1, mark.end_col),
      }
    end
  end
  table.sort(found, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    end
    return a.col < b.col
  end)
  return found
end

--- O texto que cada marca de captura cobre, na ordem das linhas: `"@keyword.lua local"`.
---@param result deckle.RenderResult
---@return string[]
local function captures(result)
  return vim.tbl_map(function(item)
    return item.hl .. " " .. item.text
  end, slices(result.lines, result.marks))
end

---@param list string[]
---@param value string
---@return boolean
local function has(list, value)
  return vim.tbl_contains(list, value)
end

--- Roda `fn` com `tbl[key]` trocado por `stub`, e restaura em qualquer caso.
---@param tbl table
---@param key string
---@param stub any
---@param fn fun()
local function with_stub(tbl, key, stub, fn)
  local saved = tbl[key]
  tbl[key] = stub
  local ok, err = pcall(fn)
  tbl[key] = saved
  if not ok then
    error(err, 0)
  end
end

--- Toda marca cai dentro de uma linha existente e de um intervalo de bytes não vazio.
---@param lines string[]
---@param marks deckle.Mark[]
---@return string[] violações
local function mark_problems(lines, marks)
  local problems = {}
  for i, mark in ipairs(marks) do
    local line = lines[mark.row + 1]
    if not line then
      problems[#problems + 1] = ("marca %d (%s) fora das linhas: row %d"):format(
        i,
        mark.hl,
        mark.row
      )
    elseif not (mark.col >= 0 and mark.col < mark.end_col and mark.end_col <= #line) then
      problems[#problems + 1] = ("marca %d (%s) fora da linha %d: [%d,%d) de %d bytes"):format(
        i,
        mark.hl,
        mark.row,
        mark.col,
        mark.end_col,
        #line
      )
    end
  end
  return problems
end

--- Bloco de Markdown com `n` linhas de Lua.
---@param n integer
---@return string
local function lua_block(n)
  local lines = { "```lua" }
  for i = 1, n do
    lines[#lines + 1] = ("local function f%d(a, b) return a + b * %d, 'x%d' end -- n %d"):format(
      i,
      i,
      i,
      i
    )
  end
  lines[#lines + 1] = "```"
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------------------
-- Moldura
-- ---------------------------------------------------------------------------------------

T["moldura"] = new_set()

T["moldura"]["caixa Unicode, com o rótulo da linguagem na borda de cima"] = function()
  local result = r("```lua\nlocal x = 1\n```", { width = 20 })
  eq(result.lines, {
    "╭─ lua ────────────╮",
    "│ local x = 1      │",
    "╰──────────────────╯",
  })
  eq(widths(result.lines), { 20, 20, 20 })
end

T["moldura"]["caixa ASCII, sem um byte fora do ASCII"] = function()
  local result = r("```lua\nlocal x = 1\n```", { width = 20, charset = "ascii" })
  eq(result.lines, {
    "+- lua ------------+",
    "| local x = 1      |",
    "+------------------+",
  })
  -- O ASCII tem as mesmas medidas do Unicode.
  local unicode = r("```lua\nlocal x = 1\n```", { width = 20 })
  eq(widths(result.lines), widths(unicode.lines))
  for _, line in ipairs(result.lines) do
    eq(line:find("[\128-\255]"), nil)
  end
  eq(table.concat(unicode.lines):find("[\128-\255]") ~= nil, true)
end

T["moldura"]["ASCII também no corpo e na borda de baixo de um bloco sem rótulo e com tab"] = function()
  local lines = r("```\na\n\tb\n```", { width = 12, charset = "ascii" }).lines
  eq(lines, { "+----------+", "| a        |", "|     b    |", "+----------+" })
end

T["moldura"]["sem info string a caixa não tem rótulo"] = function()
  local result = r("```\nx = 1\n```", { width = 14 })
  eq(result.lines, {
    "╭────────────╮",
    "│ x = 1      │",
    "╰────────────╯",
  })
  eq(slices(result.lines, result.marks, "DeckleCodeLang"), {})
end

T["moldura"]["bloco indentado (sem cerca) também é uma caixa sem rótulo"] = function()
  local result = r("    x = 1", { width = 14 })
  eq(result.lines, {
    "╭────────────╮",
    "│ x = 1      │",
    "╰────────────╯",
  })
end

T["moldura"]["o rótulo é o que veio no info string, não o nome do parser"] = function()
  eq(r("```sh\nls\n```", { width = 14 }).lines[1], "╭─ sh ───────╮")
  eq(r("```Lua\nx\n```", { width = 14 }).lines[1], "╭─ Lua ──────╮")
end

T["moldura"]["a caixa ocupa a largura inteira quando o código cabe"] = function()
  for _, width in ipairs({ 15, 16, 25, 40, 80 }) do
    local lines = r("```lua\nlocal x = 1\n\nreturn x\n```", { width = width }).lines
    eq(#lines, 5)
    eq(lines[3], "│" .. string.rep(" ", width - 2) .. "│")
    for _, line in ipairs(lines) do
      eq(cells(line), width)
    end
  end
end

T["moldura"]["código mais largo que a janela transborda: a caixa cresce e continua retangular"] = function()
  local long = string.rep("x", 60)
  local result = r("```lua\nshort\n" .. long .. "\n```", { width = 20 })
  eq(#result.lines, 4)
  eq(widths(result.lines), { 64, 64, 64, 64 })
  eq(result.lines[3], "│ " .. long .. " │")
  eq(result.lines[2], "│ short" .. string.rep(" ", 55) .. " │")
end

T["moldura"]["a linha de código vazia continua dentro da caixa"] = function()
  local lines = r("```\na\n\nb\n```", { width = 10 }).lines
  eq(lines[3], "│        │")
end

T["moldura"]["emoji e CJK: todas as linhas têm a mesma largura em células"] = function()
  local text =
    "```lua\nlocal s = '😀 日本語'\n日本語日本語\n👨‍👩‍👧 x\nplain\n```"
  for _, width in ipairs({ 10, 30, 60 }) do
    local lines = r(text, { width = width }).lines
    local expected = cells(lines[1])
    eq(expected >= width, true)
    for _, line in ipairs(lines) do
      eq(cells(line), expected)
    end
  end
end

T["moldura"]["tab vira espaço até o próximo múltiplo de 4, em células"] = function()
  eq(r("```\na\tb\n```", { width = 12 }).lines[2], "│ a   b    │")
  eq(r("```\n\t\tx\n```", { width = 14 }).lines[2], "│         x  │")
  -- O CJK ocupa duas células: o tab seguinte só tem mais duas até o múltiplo de 4.
  eq(r("```\n日\tx\n```", { width = 12 }).lines[2], "│ 日  x    │")
  -- Quatro espaços, 日 (2), tab até a célula 8 (2), 😀 (2): 10 células de código, mais 4.
  local lines = r("```\na\tb\n\t日\t😀\n```", { width = 12 }).lines
  eq(lines[3], "│     日  😀 │")
  for _, line in ipairs(lines) do
    eq(cells(line), 14)
  end
end

T["moldura"]["rótulo comprido é truncado e nunca alarga a caixa"] = function()
  local lang = string.rep("a", 40)
  local lines = r("```" .. lang .. "\nx\n```", { width = 20 }).lines
  eq(cells(lines[1]), 20)
  eq(lines[1], "╭─ aaaaaaaaaaaaa… ─╮")
  local ascii = r("```" .. lang .. "\nx\n```", { width = 20, charset = "ascii" }).lines
  eq(ascii[1], "+- aaaaaaaaaaa... -+")
  eq(ascii[1]:find("[\128-\255]"), nil)
  -- Na largura mínima ainda sobra espaço para uma parte do rótulo.
  eq(cells(r("```" .. lang .. "\nx\n```", { width = 10 }).lines[1]), 10)
end

T["moldura"]["rótulo com CJK é medido em células"] = function()
  local lines = r("```日本語\nx\n```", { width = 20 }).lines
  eq(cells(lines[1]), 20)
  eq(cells(r("```" .. string.rep("日", 30) .. "\nx\n```", { width = 20 }).lines[1]), 20)
end

T["moldura"]["marcas da moldura: borda, rótulo e fundo do corpo"] = function()
  local result = r("```lua\nab\n```", { width = 12 })
  eq(
    result.lines,
    { "╭─ lua ────╮", "│ ab       │", "╰──────────╯" }
  )
  eq(slices(result.lines, result.marks, "DeckleCodeLang")[1].text, "lua")
  local body = slices(result.lines, result.marks, "DeckleCode")
  eq(#body, 1)
  eq(body[1].text, " ab       ")
  local borders = slices(result.lines, result.marks, "DeckleCodeBorder")
  eq(
    vim.tbl_map(function(item)
      return item.text
    end, borders),
    { "╭─ ", " ────╮", "│", "│", "╰──────────╯" }
  )
end

T["moldura"]["bloco vazio não produz nada, nem a nota"] = function()
  eq({ direct({ lines = {} }) }, { {}, {} })
  eq({ direct({ lang = "lua", lines = {}, note = "x" }) }, { {}, {} })
  eq({ direct({}) }, { {}, {} })
  eq(r("```\n```").lines, {})
end

T["moldura"]["com ambiwidth=double os glifos de borda ocupam duas células e a caixa fecha"] = function()
  local saved = vim.o.ambiwidth
  local ok = pcall(function()
    vim.o.ambiwidth = "double"
  end)
  if not ok then
    -- O Neovim recusa `double` com algum `fillchars`/`listchars` ambíguo nesta máquina. Sem
    -- como medir, o caso não vale: as medidas por `strdisplaywidth` do glifo estão no código.
    return
  end
  local measured, err = pcall(function()
    -- Rótulo de largura ímpar, largura da janela ímpar, e código mais largo que a janela.
    for _, text in ipairs({
      "```lua\nlocal x = 1\n```",
      "```\nx\n```",
      "```abcd\nx\n```",
      "```lua\n" .. string.rep("x", 30) .. "\n```",
    }) do
      for _, width in ipairs({ 20, 21 }) do
        local lines = r(text, { width = width }).lines
        local expected = cells(lines[1])
        eq(expected >= width, true)
        for _, line in ipairs(lines) do
          eq(cells(line), expected)
        end
      end
    end
  end)
  vim.o.ambiwidth = saved
  if not measured then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------------------
-- Nota e bloco sintético (a API que a fase 7 usa)
-- ---------------------------------------------------------------------------------------

T["nota"] = new_set()

T["nota"]["uma linha discreta abaixo da moldura, com o próprio grupo"] = function()
  local lines, marks = direct({
    lang = "mermaid",
    lines = { "graph TD", "  A --> B" },
    note = "mermaid: native module not loaded",
  }, { width = 40 })
  eq(#lines, 5)
  eq(
    lines[1],
    "╭─ mermaid ────────────────────────────╮"
  )
  eq(lines[2], "│ graph TD                             │")
  eq(lines[3], "│   A --> B                            │")
  eq(
    lines[4],
    "╰──────────────────────────────────────╯"
  )
  eq(lines[5], "mermaid: native module not loaded")
  eq(slices(lines, marks, "DeckleCodeNote")[1].text, lines[5])
  -- Sem parser de mermaid: sem cor, só a moldura.
  eq(slices(lines, marks, "@"), {})
  eq(mark_problems(lines, marks), {})
end

T["nota"]["é truncada na largura do contexto, sem quebra de linha"] = function()
  local lines = direct({ lines = { "x" }, note = string.rep("palavra ", 20) }, { width = 20 })
  eq(#lines, 4)
  eq(cells(lines[4]), 20)
  eq(lines[4]:sub(-3), "…")
  local ascii = direct(
    { lines = { "x" }, note = "a\nb\tc " .. string.rep("z", 40) },
    { width = 20, charset = "ascii" }
  )
  eq(ascii[4], "a b c " .. string.rep("z", 11) .. "...")
  eq(cells(ascii[4]), 20)
end

T["nota"]["vazia, só espaço ou não string: não há linha de nota"] = function()
  for _, note in ipairs({ "", "   ", "\n\t" }) do
    eq(#direct({ lines = { "x" }, note = note }), 3)
  end
  eq(#direct({ lines = { "x" }, note = 42 }), 3)
  eq(#direct({ lines = { "x" } }), 3)
end

T["nota"]["o bloco do IR não tem nota: só quem chama o módulo preenche"] = function()
  eq(#r("```lua\nx\n```").lines, 3)
end

T["nota"]["bloco sintético: lang e lines bastam, e ctx pode vir quase vazio"] = function()
  local lines = code.render({ lang = "mermaid", lines = { "a" } }, { width = 20 })
  eq(lines, {
    "+- mermaid " .. string.rep("-", 8) .. "+",
    "| a" .. string.rep(" ", 16) .. "|",
    "+" .. string.rep("-", 18) .. "+",
  })
  -- Sem `charset` é ASCII, e sem `width` é 80.
  eq(cells(code.render({ lines = { "a" } }, {})[1]), 80)
  eq(cells(code.render({ lines = { "a" } })[1]), 80)
end

T["nota"]["linha de código com \\n não chega à saída"] = function()
  local lines = direct({ lines = { "a\nb" } })
  for _, line in ipairs(lines) do
    eq(line:find("\n", 1, true), nil)
  end
  eq(vim.startswith(lines[2], "│ a b"), true)
end

-- ---------------------------------------------------------------------------------------
-- Highlight
-- ---------------------------------------------------------------------------------------

T["highlight"] = new_set()

T["highlight"]["bloco lua sai colorido, com a captura e o texto exatos"] = function()
  local result = r('```lua\nlocal x = "a" -- c\nreturn x\n```')
  local found = captures(result)
  eq(found, {
    "@keyword.lua local",
    "@variable.lua x",
    "@operator.lua =",
    '@string.lua "a"',
    "@comment.lua -- c",
    "@keyword.return.lua return",
    "@variable.lua x",
  })
  eq(mark_problems(result.lines, result.marks), {})
  for _, mark in ipairs(result.marks) do
    if mark.hl:sub(1, 1) == "@" then
      eq(mark.priority, code.PRIORITY)
      eq(mark.row >= 1 and mark.row <= 2, true)
    end
  end
end

T["highlight"]["o fundo do bloco fica abaixo das capturas"] = function()
  local result = r("```lua\nlocal x\n```")
  for _, mark in ipairs(result.marks) do
    if mark.hl == "DeckleCode" then
      eq(mark.priority, code.BODY_PRIORITY)
      eq(mark.priority < code.PRIORITY, true)
    end
  end
end

T["highlight"]["as marcas são em bytes: UTF-8 multibyte no código e antes da captura"] = function()
  local result =
    r('```lua\nlocal s = "ñandú 日本 😀" -- ção\nlocal t = "é"\n```', { width = 12 })
  local found = captures(result)
  eq(has(found, '@string.lua "ñandú 日本 😀"'), true)
  eq(has(found, "@comment.lua -- ção"), true)
  eq(has(found, '@string.lua "é"'), true)
  eq(has(found, "@keyword.lua local"), true)
  eq(mark_problems(result.lines, result.marks), {})
end

T["highlight"]["tab antes da captura: a marca acompanha o texto expandido"] = function()
  local result = r("```lua\n\tlocal x\n\t\treturn x -- \tc\n```")
  local found = captures(result)
  eq(has(found, "@keyword.lua local"), true)
  eq(has(found, "@keyword.return.lua return"), true)
  eq(has(found, "@comment.lua -- \tc"), false)
  eq(has(found, "@comment.lua --     c"), true)
  eq(result.lines[2], "│     local x" .. string.rep(" ", 15) .. " │")
  eq(mark_problems(result.lines, result.marks), {})
end

T["highlight"]["o parser recebe o texto original: o tab não é trocado antes do parse"] = function()
  local seen
  local original = vim.treesitter.get_string_parser
  with_stub(vim.treesitter, "get_string_parser", function(src, lang, ...)
    seen = src
    return original(src, lang, ...)
  end, function()
    r("```lua\n\tlocal x\n```")
  end)
  eq(seen, "\tlocal x")
end

T["highlight"]["captura de várias linhas vira uma marca por linha, sem marca na linha vazia"] = function()
  local result = r("```lua\nlocal s = [[a\n\n  b]]\nreturn s\n```", { width = 20 })
  local strings = vim.tbl_filter(function(item)
    return item.hl == "@string.lua"
  end, slices(result.lines, result.marks))
  eq(
    vim.tbl_map(function(item)
      return { item.row, item.text }
    end, strings),
    { { 1, "[[a" }, { 3, "  b]]" } }
  )
  eq(mark_problems(result.lines, result.marks), {})
end

T["highlight"]["marca nenhuma cobre a borda: só o texto do código"] = function()
  local result = r("```lua\nlocal x = 1\n```", { width = 40 })
  local seen = 0
  for _, mark in ipairs(result.marks) do
    if mark.hl:sub(1, 1) == "@" then
      seen = seen + 1
      eq(mark.col >= #"│ ", true)
      eq(mark.end_col <= #result.lines[mark.row + 1] - #" │", true)
    end
  end
  eq(seen > 0, true)
end

T["highlight"]["dentro de quote e de lista as marcas acompanham o prefixo do contêiner"] = function()
  for _, text in ipairs({ "> ```lua\n> local x = 1\n> ```", "- ```lua\n  local x = 1\n  ```" }) do
    local result = r(text, { width = 30 })
    local found = captures(result)
    eq(has(found, "@keyword.lua local"), true)
    eq(has(found, "@variable.lua x"), true)
    eq(has(found, "@number.lua 1"), true)
    eq(mark_problems(result.lines, result.marks), {})
    for _, line in ipairs(result.lines) do
      eq(cells(line), 30)
    end
  end
end

T["highlight"]["nome com maiúscula acha o parser"] = function()
  eq(has(captures(r("```Lua\nlocal x\n```")), "@keyword.lua local"), true)
  eq(has(captures(r("```LUA\nlocal x\n```")), "@keyword.lua local"), true)
end

T["highlight"]["info string com atributos: só a primeira palavra é a linguagem"] = function()
  local result = r('```lua title="x.lua"\nlocal x\n```', { width = 20 })
  eq(has(captures(result), "@keyword.lua local"), true)
  eq(result.lines[1], "╭─ lua ────────────╮")
end

T["highlight"]["core: c, lua e vim têm parser e query de highlights"] = function()
  for lang, sample in pairs({ c = "int main(void) { return 0; }", vim = "let x = 1" }) do
    local result = r("```" .. lang .. "\n" .. sample .. "\n```", { width = 40 })
    eq(#captures(result) > 0, true)
    for _, item in ipairs(slices(result.lines, result.marks)) do
      eq(item.hl:sub(-#lang - 1), "." .. lang)
    end
  end
end

-- ---------------------------------------------------------------------------------------
-- Linguagem
-- ---------------------------------------------------------------------------------------

T["linguagem"] = new_set()

--- Roda `fn` com `language.add` aceitando só os parsers de `available`, e devolve os nomes
--- que ele recebeu.
---@param available string[]
---@param fn fun()
---@return string[]
local function with_parsers(available, fn)
  local asked = {}
  with_stub(vim.treesitter.language, "add", function(lang)
    asked[#asked + 1] = lang
    if vim.tbl_contains(available, lang) then
      return true
    end
    return nil, 'No parser for language "' .. tostring(lang) .. '"'
  end, fn)
  return asked
end

T["linguagem"]["todo alias aponta para o parser dele"] = function()
  local count = 0
  for alias, target in pairs(code.ALIASES) do
    with_parsers({ target }, function()
      eq({ alias, code.resolve_lang(alias) }, { alias, target })
    end)
    count = count + 1
  end
  eq(count >= 30, true)
  -- Os que o roadmap pede, por nome.
  with_parsers({ "bash", "javascript", "python", "typescript" }, function()
    eq(code.resolve_lang("sh"), "bash")
    eq(code.resolve_lang("js"), "javascript")
    eq(code.resolve_lang("py"), "python")
    eq(code.resolve_lang("ts"), "typescript")
  end)
end

T["linguagem"]["sem o parser do alias, nada resolve"] = function()
  with_parsers({}, function()
    eq(code.resolve_lang("sh"), nil)
    eq(code.resolve_lang("js"), nil)
    eq(code.resolve_lang("lua"), nil)
  end)
end

T["linguagem"]["o parser com o nome do próprio info string vale sem alias"] = function()
  with_parsers({ "zig" }, function()
    eq(code.resolve_lang("zig"), "zig")
    eq(code.resolve_lang("ZIG"), "zig")
  end)
end

T["linguagem"]["extensão de arquivo vira filetype vira parser"] = function()
  -- `kts` não é alias nosso: o Neovim sabe que é Kotlin.
  eq(code.ALIASES.kts, nil)
  with_parsers({ "kotlin" }, function()
    eq(code.resolve_lang("kts"), "kotlin")
  end)
end

T["linguagem"]["o que o usuário registrou com `register` vem antes da tabela de aliases"] = function()
  vim.treesitter.language.register("lua", "deckle_test_ft")
  eq(code.resolve_lang("deckle_test_ft"), "lua")
  eq(has(captures(r("```deckle_test_ft\nlocal x\n```")), "@keyword.lua local"), true)
  -- Sobre um alias nosso: `viml` é `vim` na tabela, e aqui o usuário o manda para `lua`.
  eq(code.ALIASES.viml, "vim")
  vim.treesitter.language.register("lua", "viml")
  local resolved = code.resolve_lang("viml")
  vim.treesitter.language.register("vim", "viml")
  eq(resolved, "lua")
end

T["linguagem"]["nome que não é parser nunca chega ao language.add"] = function()
  local bad = { "../../etc/x", "a/b", "lua; rm", "..", "a b", "x\0y", "", "-lua", "lua-" }
  local asked = with_parsers({ "lua" }, function()
    for _, name in ipairs(bad) do
      eq({ name, code.resolve_lang(name) }, { name, nil })
    end
    eq(code.resolve_lang(nil), nil)
    eq(code.resolve_lang(42), nil)
  end)
  eq(asked, {})
end

T["linguagem"]["nome inválido no bloco: sem cor, sem erro, com a moldura"] = function()
  local result = r("```../../etc/passwd\nlocal x\n```", { width = 24 })
  eq(#result.lines, 3)
  eq(captures(result), {})
  eq(render.last_error, nil)
end

T["linguagem"]["markdown não é colorido e o treesitter nem é chamado"] = function()
  local called = {}
  local original = vim.treesitter.get_string_parser
  with_stub(vim.treesitter, "get_string_parser", function(src, lang, ...)
    called[#called + 1] = lang
    return original(src, lang, ...)
  end, function()
    -- Direto no módulo: o parse do documento (`parse.lua`) usa o parser de Markdown.
    for _, name in ipairs({ "markdown", "md", "MarkDown", "markdown_inline" }) do
      local lines, marks = direct({ lang = name, lines = { "# t", "- > a" } }, { width = 20 })
      eq(slices(lines, marks), {})
      eq(#lines, 4)
    end
  end)
  eq(called, {})
  eq(code.stats.parses, 0)
end

-- ---------------------------------------------------------------------------------------
-- Degradação (ADR-0004)
-- ---------------------------------------------------------------------------------------

T["degradação"] = new_set()

--- O mesmo bloco, sem cor: as mesmas linhas de quando o parser existe, e nenhuma marca `@`.
---@param colored deckle.RenderResult
---@param result deckle.RenderResult
local function eq_uncolored(colored, result)
  eq(#captures(colored) > 0, true)
  eq(result.lines, colored.lines)
  eq(captures(result), {})
  eq(#result.marks < #colored.marks, true)
end

--- Roda `fn` contando as chamadas de `vim.notify`.
---@param fn fun()
---@return integer
local function count_notify(fn)
  local n = 0
  with_stub(vim, "notify", function()
    n = n + 1
  end, fn)
  return n
end

--- Esconde o parser de `lua` e só ele: o parse do Markdown (`parse.lua`) usa o mesmo
--- `language.add`, `get_string_parser` e `query.get`, e com eles quebrados o documento nem
--- chegaria ao bloco de código. `failure` recebe os argumentos da chamada e devolve o que a
--- função falha devolveria (ou lança).
---@param tbl table
---@param key string
---@param lang_arg integer posição do argumento que é o nome da linguagem
---@param failure fun(...): any
---@param fn fun()
local function hide_lua(tbl, key, lang_arg, failure, fn)
  local real = tbl[key]
  with_stub(tbl, key, function(...)
    if select(lang_arg, ...) == "lua" then
      return failure(...)
    end
    return real(...)
  end, fn)
end

T["degradação"]["linguagem inexistente: sem cor, sem erro, sem notify"] = function()
  local result
  local notified = count_notify(function()
    result = r("```nenhuma_linguagem\nlocal x = 1\n```", { width = 24 })
  end)
  eq(result.lines, {
    "╭─ nenhuma_linguagem ──╮",
    "│ local x = 1" .. string.rep(" ", 9) .. " │",
    "╰" .. string.rep("─", 22) .. "╯",
  })
  eq(captures(result), {})
  eq(#slices(result.lines, result.marks, "DeckleCode"), 1)
  eq(render.last_error, nil)
  eq(notified, 0)
end

T["degradação"]["parser real ausente (language.add falha): sem cor, sem erro, sem notify"] = function()
  local text = "```lua\nlocal x = 1\n```"
  local colored = r(text)
  local failures = {
    function()
      return nil, 'No parser for language "lua"'
    end,
    function()
      return false
    end,
    function()
      error("boom: parser not found")
    end,
  }
  for _, failure in pairs(failures) do
    local result
    local notified = count_notify(function()
      hide_lua(vim.treesitter.language, "add", 1, failure, function()
        result = r(text)
      end)
    end)
    eq_uncolored(colored, result)
    eq(render.last_error, nil)
    eq(notified, 0)
  end
end

T["degradação"]["get_string_parser que lança: sem cor, sem erro, com o motivo em last_error"] = function()
  local text = "```lua\nlocal x = 1\n```"
  local colored = r(text)
  code.clear_cache()
  local result
  local notified = count_notify(function()
    hide_lua(vim.treesitter, "get_string_parser", 2, function()
      error("parser exploded")
    end, function()
      result = r(text)
    end)
  end)
  eq_uncolored(colored, result)
  eq(render.last_error, nil)
  eq(notified, 0)
  eq(code.last_error:match("parser exploded") ~= nil, true)
end

T["degradação"]["query de highlights ausente ou que lança: sem cor, sem erro"] = function()
  local text = "```lua\nlocal x = 1\n```"
  local colored = r(text)
  for _, failure in pairs({
    function()
      return nil
    end,
    function()
      error("invalid query")
    end,
  }) do
    code.clear_cache()
    code.last_error = nil
    local result
    hide_lua(vim.treesitter.query, "get", 1, failure, function()
      result = r(text)
    end)
    eq_uncolored(colored, result)
    eq(render.last_error, nil)
    eq(code.last_error ~= nil, true)
  end
end

T["degradação"]["parser que não devolve árvore, que lança ao parsear e que lança ao ser percorrido"] = function()
  local text = "```lua\nlocal x = 1\n```"
  local colored = r(text)
  local cases = {
    function()
      return {
        parse = function()
          return {}
        end,
      }
    end,
    function()
      return {
        parse = function()
          error("parse failed")
        end,
      }
    end,
    function()
      return {
        parse = function()
          return {
            {
              root = function()
                error("root failed")
              end,
            },
          }
        end,
      }
    end,
  }
  for _, failure in pairs(cases) do
    code.clear_cache()
    local result
    hide_lua(vim.treesitter, "get_string_parser", 2, failure, function()
      result = r(text)
    end)
    eq_uncolored(colored, result)
    eq(render.last_error, nil)
  end
end

T["degradação"]["a falha não fica no cache: com o parser de volta o bloco ganha cor"] = function()
  local text = "```lua\nlocal x = 1\n```"
  hide_lua(vim.treesitter.language, "add", 1, function()
    return nil, "gone"
  end, function()
    eq(captures(r(text)), {})
    eq(captures(r(text)), {})
  end)
  eq(#captures(r(text)) > 0, true)

  hide_lua(vim.treesitter, "get_string_parser", 2, function()
    error("boom")
  end, function()
    code.clear_cache()
    eq(captures(r(text)), {})
  end)
  eq(#captures(r(text)) > 0, true)
end

T["degradação"]["um bloco sem cor não leva o resto do documento junto"] = function()
  local text = "```nenhuma\na\n```\n\n```lua\nlocal x\n```\n\ntexto **forte**"
  local result = r(text, { width = 24 })
  eq(has(captures(result), "@keyword.lua local"), true)
  eq(result.lines[#result.lines], "texto forte")
  eq(render.last_error, nil)
end

T["degradação"]["sem info string: sem cor, mesmo com cara de Lua"] = function()
  eq(captures(r("```\nlocal x = 1\nreturn x\n```")), {})
  eq(captures(r("    local x = 1\n    return x")), {})
  eq(code.stats.parses, 0)
end

-- ---------------------------------------------------------------------------------------
-- Tamanho e cache
-- ---------------------------------------------------------------------------------------

T["tamanho"] = new_set()

T["tamanho"]["bloco de 2000 linhas renderiza colorido e sem travar"] = function()
  local ir = parse.parse_lines(lua_block(2000))
  eq(#ir[1].lines, 2000)
  local start = vim.uv.hrtime()
  local result = render.render(ir, { width = 80, charset = "unicode" })
  local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
  eq(#result.lines, 2002)
  eq(#captures(result) > 10000, true)
  eq(mark_problems(result.lines, result.marks), {})
  -- Orçamento folgado para a CI: medido em ~70 ms numa máquina local.
  eq({ elapsed_ms < 500, elapsed_ms }, { true, elapsed_ms })
  eq(render.last_error, nil)
end

T["tamanho"]["bloco de 2000 linhas sem parser também não trava"] = function()
  local text = lua_block(2000):gsub("```lua", "```nenhuma", 1)
  local start = vim.uv.hrtime()
  local result = r(text, { width = 80 })
  local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
  eq(#result.lines, 2002)
  eq(captures(result), {})
  eq({ elapsed_ms < 500, elapsed_ms }, { true, elapsed_ms })
end

T["tamanho"]["linha de 100 mil colunas não trava e não quebra a moldura"] = function()
  local long = "local s = '" .. string.rep("x", 100000) .. "'"
  local start = vim.uv.hrtime()
  local result = r("```lua\n" .. long .. "\n```")
  local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
  local expected = cells(long) + 4
  eq(widths(result.lines), { expected, expected, expected })
  eq(has(captures(result), "@keyword.lua local"), true)
  eq({ elapsed_ms < 500, elapsed_ms }, { true, elapsed_ms })
end

T["tamanho"]["acima do teto de linhas ou de bytes o bloco sai sem cor, com moldura"] = function()
  local saved = { lines = code.MAX_HIGHLIGHT_LINES, bytes = code.MAX_HIGHLIGHT_BYTES }
  local ok, err = pcall(function()
    code.MAX_HIGHLIGHT_LINES = 5
    eq(#captures(r(lua_block(5))) > 0, true)
    local over = r(lua_block(6))
    eq(captures(over), {})
    eq(#over.lines, 8)
    eq(code.stats.parses, 1)

    code.MAX_HIGHLIGHT_LINES = saved.lines
    code.MAX_HIGHLIGHT_BYTES = 50
    eq(captures(r(lua_block(1))), {})
    eq(#captures(r("```lua\nlocal x\n```")) > 0, true)
  end)
  code.MAX_HIGHLIGHT_LINES, code.MAX_HIGHLIGHT_BYTES = saved.lines, saved.bytes
  if not ok then
    error(err, 0)
  end
end

T["cache"] = new_set()

T["cache"]["renderizar de novo o mesmo bloco não reparseia"] = function()
  local ir = parse.parse_lines("```lua\nlocal x = 1\n```")
  local first = render.render(ir, { width = 30, charset = "unicode" })
  eq(code.stats, { parses = 1, hits = 0 })
  local second = render.render(ir, { width = 30, charset = "unicode" })
  eq(code.stats, { parses = 1, hits = 1 })
  eq(second, first)
  -- Outra largura e outro charset mudam a caixa, não o parse.
  render.render(ir, { width = 50, charset = "ascii" })
  eq(code.stats, { parses = 1, hits = 2 })
end

T["cache"]["fonte diferente reparseia; o mesmo parser sob outro nome não"] = function()
  r("```lua\nlocal x = 1\n```")
  eq(code.stats.parses, 1)
  r("```lua\nlocal x = 2\n```")
  eq(code.stats.parses, 2)
  r("```Lua\nlocal x = 2\n```")
  eq(code.stats.parses, 2)
  eq(code.stats.hits, 1)
  r("```c\nint x;\n```")
  eq(code.stats.parses, 3)
  -- O mesmo texto em outra linguagem não é o mesmo bloco.
  r("```lua\nint x;\n```")
  eq(code.stats.parses, 4)
end

T["cache"]["o acerto devolve as mesmas marcas de um parse novo"] = function()
  local text = "```lua\nlocal s = 'ñ'\n\treturn s\n```"
  local cold = r(text)
  local warm = r(text)
  eq(code.stats.hits, 1)
  eq(warm, cold)
  code.clear_cache()
  eq(r(text), cold)
  eq(code.stats.parses, 2)
end

T["cache"]["um documento com vários blocos iguais parseia uma vez por bloco distinto"] = function()
  local parts = {}
  for i = 1, 10 do
    parts[i] = "```lua\nlocal x = " .. (i % 3) .. "\n```"
  end
  r(table.concat(parts, "\n\n"))
  eq(code.stats.parses, 3)
  eq(code.stats.hits, 7)
end

--- Roda `fn` com os tetos do cache trocados.
---@param entries integer
---@param weight integer
---@param fn fun()
local function with_cache_limits(entries, weight, fn)
  local saved = { code.MAX_CACHE_ENTRIES, code.MAX_CACHE_WEIGHT }
  code.MAX_CACHE_ENTRIES, code.MAX_CACHE_WEIGHT = entries, weight
  local ok, err = pcall(fn)
  code.MAX_CACHE_ENTRIES, code.MAX_CACHE_WEIGHT = saved[1], saved[2]
  if not ok then
    error(err, 0)
  end
end

---@param i integer
---@return deckle.RenderResult
local function distinct(i)
  return r("```lua\nlocal x = " .. i .. "\n```")
end

T["cache"]["tem teto: centenas de blocos distintos não o enchem"] = function()
  with_cache_limits(10, 1000000, function()
    for i = 1, 100 do
      distinct(i)
    end
    eq(code.stats.parses, 100)
    eq({ code.cache_size() > 0, code.cache_size() <= 20 }, { true, true })
    -- O que acabou de ser usado continua lá.
    distinct(100)
    eq(code.stats, { parses = 100, hits = 1 })
  end)
end

T["cache"]["a geração antiga ainda acerta, e o acerto a promove"] = function()
  with_cache_limits(4, 1000000, function()
    for i = 1, 5 do
      distinct(i)
    end
    -- Os blocos 1 a 4 viraram a geração antiga quando o 5º entrou.
    eq(code.cache_size(), 5)
    distinct(1)
    eq(code.stats, { parses = 5, hits = 1 })
    -- Mais quatro entradas viram a geração, e o 1 (promovido) sobrevive, o 2 não.
    for i = 6, 8 do
      distinct(i)
    end
    distinct(1)
    eq(code.stats, { parses = 8, hits = 2 })
    distinct(2)
    eq(code.stats.parses, 9)
  end)
end

T["cache"]["teto de capturas: o bloco grande demais não entra"] = function()
  with_cache_limits(256, 100, function()
    local text = lua_block(50)
    r(text)
    r(text)
    eq(code.stats, { parses = 2, hits = 0 })
    eq(code.cache_size(), 0)
  end)
end

-- ---------------------------------------------------------------------------------------
-- Preview de verdade
-- ---------------------------------------------------------------------------------------

local child = MiniTest.new_child_neovim()

T["preview"] = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.columns = 100
      child.o.lines = 30
      -- `charset = "auto"` vira ASCII com TERM=linux/dumb, que é o que uma CI pode ter, e o caso
      -- da cor procura a borda Unicode da moldura. O ambiente de quem roda não entra.
      child.lua([[vim.env.TERM = "xterm-256color"]])
    end,
    post_once = child.stop,
  },
})

---@param lines string[]
local function use_source(lines)
  child.lua(
    [[
      vim.cmd("enew")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, (...))
      vim.bo.filetype = "markdown"
      _G.src = vim.api.nvim_get_current_buf()
    ]],
    { lines }
  )
end

T["preview"]["o bloco lua chega ao buffer de preview como extmark de treesitter"] = function()
  use_source({ "# t", "", "```lua", "local x = 1", "```", "", "```nenhuma", "local y", "```" })
  child.cmd("Deckle open")
  local found = child.lua_get([[(function()
    local st = require("deckle.preview").state(_G.src)
    local ns = require("deckle.preview").ns
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, ns, 0, -1, { details = true })) do
      local hl = m[4].hl_group
      if hl:sub(1, 1) == "@" then
        local line = vim.api.nvim_buf_get_lines(st.buf, m[2], m[2] + 1, false)[1]
        table.insert(out, { hl = hl, row = m[2], text = line:sub(m[3] + 1, m[4].end_col) })
      end
    end
    return out
  end)()]])
  eq(found, {
    { hl = "@keyword.lua", row = 4, text = "local" },
    { hl = "@variable.lua", row = 4, text = "x" },
    { hl = "@operator.lua", row = 4, text = "=" },
    { hl = "@number.lua", row = 4, text = "1" },
  })
  -- ADR-0003: o fonte não ganha nada do deckle (extmarks de outros plugins e do próprio
  -- Neovim, como os do filetype markdown no nightly, não são da conta dele).
  local source_marks = child.lua_get([[(function()
    local n = 0
    for name, id in pairs(vim.api.nvim_get_namespaces()) do
      if name:find("^deckle") then
        n = n + #vim.api.nvim_buf_get_extmarks(_G.src, id, 0, -1, {})
      end
    end
    return n
  end)()]])
  eq(source_marks, 0)
  eq(child.lua_get("vim.bo[_G.src].modifiable"), true)
end

T["preview"]["a cor chega à tela: o `local` tem atributo diferente do texto sem captura"] = function()
  child.cmd("colorscheme default")
  use_source({ "```lua", "local x = 1", "```" })
  child.cmd("Deckle open")
  local shot = child.get_screenshot()
  -- A linha do código na tela: o preview é a janela da direita, e a da esquerda (o fonte)
  -- tem `local x = 1` também, sem a borda na frente.
  local needle = { "│", " ", "l", "o", "c", "a", "l" }
  local row, at
  for i, text in ipairs(shot.text) do
    for c = 1, #text - #needle + 1 do
      local match = true
      for k = 1, #needle do
        match = match and text[c + k - 1] == needle[k]
      end
      if match then
        row, at = i, c
      end
    end
  end
  eq(row ~= nil, true)
  local attr = shot.attr[row]
  local keyword = at + 2
  -- O fim do corpo, depois do `1`: só o fundo do `DeckleCode`, sem captura nenhuma.
  local pad = at + 13
  eq(shot.text[row][pad], " ")
  -- `local` é `@keyword` (Statement), e tem atributo próprio sobre o fundo do corpo.
  eq(attr[keyword] ~= attr[pad], true)
end

return T
