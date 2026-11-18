-- Testes de `deckle.render` (fase 2): o contrato `render(ir, opts) -> { lines, marks, map }`,
-- o módulo de cada tipo e o dispatcher.
--
-- Largura é medida com `vim.fn.strdisplaywidth` em todo teste de wrap. O caso que quebra
-- implementação é conferir `#linha`: emoji e CJK entram aqui desde já (CLAUDE.md, regra 6).
--
-- O caminho de degradação (módulo de tipo que lança, bloco desconhecido) é forçado, não
-- comentado (ADR-0004).

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h")
local H = dofile(tests_dir .. "/helpers.lua")

local parse = require("deckle.parse")
local render = require("deckle.render")
local inline = require("deckle.render.inline")

local T = new_set()

-- ---------------------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------------------

---@param s string
---@return integer
local function cells(s)
  return vim.fn.strdisplaywidth(s)
end

--- Renderiza `text` (Markdown) na largura 40 e em Unicode, a não ser que `opts` diga outra
--- coisa.
---@param text string
---@param opts table|nil
---@return deckle.RenderResult
local function r(text, opts)
  local merged = vim.tbl_extend("force", { width = 40, charset = "unicode" }, opts or {})
  return render.render(parse.parse_lines(text), merged)
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

--- Texto coberto pelas marcas de `hl`, na ordem em que aparecem nas linhas.
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

--- Roda `fn` com o módulo `name` substituído por `stub` e restaura em qualquer caso.
---@param name string
---@param stub table
---@param fn fun()
local function with_module(name, stub, fn)
  local saved = package.loaded[name]
  package.loaded[name] = stub
  local ok, err = pcall(fn)
  package.loaded[name] = saved
  if not ok then
    error(err, 0)
  end
end

--- Toda marca cai dentro de uma linha existente e de um intervalo de bytes não vazio.
---@param result deckle.RenderResult
---@return string[] violações
local function mark_problems(result)
  local problems = {}
  for i, mark in ipairs(result.marks) do
    local line = result.lines[mark.row + 1]
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

--- O mapa é coerente com o IR e com as linhas.
---@param ir deckle.Block[]
---@param result deckle.RenderResult
---@return string[] violações
local function map_problems(ir, result)
  local problems = {}
  local previous_end
  -- Bloco que renderiza zero linhas (um fence vazio) não tem entrada: cada entrada casa com
  -- um bloco do IR a partir do último casado, em ordem.
  local cursor = 0
  for i, entry in ipairs(result.map) do
    local found = false
    while not found and cursor < #ir do
      cursor = cursor + 1
      found = ir[cursor].src_start == entry.src_start and ir[cursor].src_end == entry.src_end
    end
    if not found then
      problems[#problems + 1] = "entrada " .. i .. " não bate com nenhum bloco do IR"
    end
    if entry.preview_end <= entry.preview_start then
      problems[#problems + 1] = "entrada " .. i .. " vazia"
    end
    if entry.preview_end > #result.lines then
      problems[#problems + 1] = "entrada " .. i .. " passa do fim das linhas"
    end
    if previous_end then
      if entry.preview_start ~= previous_end + 1 then
        problems[#problems + 1] = "entrada "
          .. i
          .. " não vem uma linha em branco depois da anterior"
      elseif result.lines[previous_end + 1] ~= "" then
        problems[#problems + 1] = "o separador antes da entrada " .. i .. " não é uma linha vazia"
      end
    elseif entry.preview_start ~= 0 then
      problems[#problems + 1] = "a primeira entrada não começa na linha 0"
    end
    previous_end = entry.preview_end
  end
  if previous_end and previous_end ~= #result.lines then
    problems[#problems + 1] = "sobram linhas depois da última entrada"
  end
  return problems
end

-- ---------------------------------------------------------------------------------------
-- Contrato
-- ---------------------------------------------------------------------------------------

T["contrato"] = new_set()

T["contrato"]["devolve lines, marks e map"] = function()
  local result = r("# oi\n\ntexto")
  eq(type(result.lines), "table")
  eq(type(result.marks), "table")
  eq(type(result.map), "table")
  eq(result.lines[1], "oi")
end

T["contrato"]["IR vazio dá resultado vazio e válido"] = function()
  eq(render.render({}, {}), { lines = {}, marks = {}, map = {} })
  eq(render.render(nil, nil), { lines = {}, marks = {}, map = {} })
  eq(r("").lines, {})
  eq(r("   \n\n").map, {})
end

T["contrato"]["largura abaixo do mínimo sobe para o mínimo"] = function()
  local result = r("uma frase razoavelmente longa para quebrar", { width = 1 })
  eq(widest(result.lines) <= render.MIN_WIDTH, true)
  eq(#result.lines > 1, true)
  eq(render.render({}, { width = 0 }).lines, {})
end

T["contrato"]["sem largura usa 80"] = function()
  local result = render.render(parse.parse_lines(string.rep("palavra ", 30)), { charset = "ascii" })
  eq(widest(result.lines) <= 80, true)
  eq(widest(result.lines) > 40, true)
end

T["contrato"]["marcas e mapa são coerentes em todos os tipos de bloco"] = function()
  local text = table.concat({
    "# Título **forte**",
    "",
    "Parágrafo com `código`, [link](http://x.y) e ![img](a.png).",
    "",
    "- item",
    "  - sub",
    "- [x] feito",
    "",
    "> citação",
    "> > fundo",
    "",
    "---",
    "",
    "```lua",
    "local x = 1",
    "```",
    "",
    "| a | b |",
    "|---|---|",
    "| 1 | 2 |",
    "",
    "<div>x</div>",
  }, "\n")
  local ir = parse.parse_lines(text)
  local result = render.render(ir, { width = 30, charset = "unicode" })
  eq(#result.map, #ir)
  eq(mark_problems(result), {})
  eq(map_problems(ir, result), {})
end

T["contrato"]["o contexto chega ao módulo de tipo com largura, charset, recuo e profundidade"] = function()
  local seen
  with_module("deckle.render.paragraph", {
    render = function(_, ctx)
      seen = {
        width = ctx.width,
        charset = ctx.charset,
        indent = ctx.indent,
        depth = ctx.depth,
        list_level = ctx.list_level,
        has_block = type(ctx.block) == "function",
      }
      return { "x" }, {}
    end,
  }, function()
    -- Uma lista (`• `, 2 células) com um quote dentro (`│ `, 2 células) com um parágrafo.
    render.render(parse.parse_lines("- > texto"), { width = 40, charset = "unicode" })
  end)
  eq(seen, {
    width = 36,
    charset = "unicode",
    indent = 4,
    depth = 2,
    list_level = 1,
    has_block = true,
  })
end

T["contrato"]["um bloco de topo recebe a largura inteira e profundidade 0"] = function()
  local seen
  with_module("deckle.render.paragraph", {
    render = function(_, ctx)
      seen = { width = ctx.width, indent = ctx.indent, depth = ctx.depth }
      return { "x" }, {}
    end,
  }, function()
    render.render(parse.parse_lines("texto"), { width = 55 })
  end)
  eq(seen, { width = 55, indent = 0, depth = 0 })
end

-- ---------------------------------------------------------------------------------------
-- Degradação
-- ---------------------------------------------------------------------------------------

T["degradação"] = new_set()

T["degradação"]["módulo de tipo que lança degrada só aquele bloco"] = function()
  render.last_error = nil
  local result
  with_module("deckle.render.rule", {
    render = function()
      error("boom")
    end,
  }, function()
    result = r("antes\n\n---\n\ndepois")
  end)
  eq(result.lines, { "antes", "", "[deckle: could not render rule block]", "", "depois" })
  eq(marked(result, "DeckleError"), { "[deckle: could not render rule block]" })
  eq(render.last_error:match("boom") ~= nil, true)
  eq(#result.map, 3)
end

T["degradação"]["módulo que não devolve linhas também degrada"] = function()
  local result
  with_module("deckle.render.rule", {
    render = function()
      return nil
    end,
  }, function()
    result = r("---")
  end)
  eq(result.lines, { "[deckle: could not render rule block]" })
end

T["degradação"]["módulo que lança dentro de um contêiner degrada só o filho"] = function()
  local result
  with_module("deckle.render.rule", {
    render = function()
      error("boom")
    end,
  }, function()
    result = r("> a\n>\n> ---")
  end)
  eq(result.lines[1], "│ a")
  eq(result.lines[#result.lines], "│ [deckle: could not render rule block]")
end

T["degradação"]["bloco de tipo desconhecido vira aviso, sem lançar"] = function()
  render.last_error = nil
  local result = render.render({ { kind = "bogus", src_start = 0, src_end = 1 } }, {})
  eq(result.lines, { "[deckle: could not render bogus block]" })
  eq(render.last_error:match("unknown block kind") ~= nil, true)
  eq(#result.map, 1)
  eq(render.render({ "não é bloco" }, {}).lines, { "[deckle: could not render string block]" })
end

T["degradação"]["o dispatcher usa o módulo carregado, o que deixa as fases 4 e 5 trocarem o fallback"] = function()
  local result
  with_module("deckle.render.code", {
    render = function(block)
      return { "<" .. #block.lines .. ">" }, {}
    end,
  }, function()
    result = r("```\na\nb\n```")
  end)
  eq(result.lines, { "<2>" })
end

-- ---------------------------------------------------------------------------------------
-- Wrap
-- ---------------------------------------------------------------------------------------

T["wrap"] = new_set()

T["wrap"]["quebra ASCII na largura e não perde palavra"] = function()
  local words = {}
  for i = 1, 40 do
    words[i] = "palavra" .. i
  end
  local text = table.concat(words, " ")
  local lines = r(text, { width = 30 }).lines
  eq(widest(lines) <= 30, true)
  eq(#lines > 5, true)
  eq(table.concat(lines, " "), text)
  for _, line in ipairs(lines) do
    eq(line:match("^%s") == nil and line:match("%s$") == nil, true)
  end
end

T["wrap"]["linha de emoji: largura em células, não em bytes"] = function()
  -- 30 emoji de 4 bytes e 2 células: 120 bytes, 60 células.
  local text = string.rep("😀", 30)
  local lines = r(text, { width = 20 }).lines
  eq(#lines, 3)
  for _, line in ipairs(lines) do
    eq(cells(line), 20)
    -- `#line` (40) passaria de 20: um wrap por bytes teria quebrado em cinco por linha.
    eq(#line, 40)
  end
  eq(table.concat(lines), text)
end

T["wrap"]["emoji que não cabe na célula que sobra vai para a linha seguinte"] = function()
  -- Largura 11: cabem 5 emoji (10 células), o sexto passaria para 12.
  local lines = r(string.rep("😀", 12), { width = 11 }).lines
  eq(#lines, 3)
  eq(cells(lines[1]), 10)
  eq(widest(lines) <= 11, true)
end

T["wrap"]["emoji no meio de texto com espaços"] = function()
  local text =
    "olá 😀 mundo 🎉 isto 🚀 é um teste de quebra com emoji 👍 espalhado pelo texto"
  local lines = r(text, { width = 24 }).lines
  eq(widest(lines) <= 24, true)
  eq(#lines > 2, true)
  eq(table.concat(lines, " "), text)
end

T["wrap"]["linha de CJK: quebra sem espaço, na largura de display"] = function()
  -- 30 caracteres de 3 bytes e 2 células: 90 bytes, 60 células.
  local text = string.rep("日本語", 10)
  local lines = r(text, { width = 25 }).lines
  eq(widest(lines) <= 25, true)
  eq(#lines, 3)
  -- Sem espaço entre os pedaços: CJK não é separado por espaço, e a quebra não inventa um.
  eq(table.concat(lines), text)
  eq(cells(lines[1]), 24)
end

T["wrap"]["CJK misturado com latim"] = function()
  local text =
    "hello 世界 world 你好 and more 日本語のテキスト mixed with ASCII 한국어 too"
  local lines = r(text, { width = 22 }).lines
  eq(widest(lines) <= 22, true)
  eq(#lines > 2, true)
  -- Sem espaço sobrando nem faltando: tirar os espaços dá o mesmo texto.
  eq((table.concat(lines):gsub("%s", "")), (text:gsub("%s", "")))
end

T["wrap"]["sequência com ZWJ não é partida"] = function()
  local family = "👨‍👩‍👧"
  eq(cells(family), 2)
  -- 8 sequências são 16 células; na largura mínima (10) cabem 5 por linha.
  local lines = r(string.rep(family, 8), { width = render.MIN_WIDTH }).lines
  eq(#lines, 2)
  eq(widest(lines) <= render.MIN_WIDTH, true)
  for _, line in ipairs(lines) do
    for _, cluster in ipairs(vim.fn.split(line, "\\zs")) do
      eq(cluster, family)
    end
  end
end

T["wrap"]["acento combinante fica com a letra"] = function()
  local accented = "e\204\129" -- e + U+0301
  local lines = r(string.rep(accented, 30), { width = 10 }).lines
  eq(#lines, 3)
  for _, line in ipairs(lines) do
    local clusters = vim.fn.split(line, "\\zs")
    eq(#clusters, 10)
    for _, cluster in ipairs(clusters) do
      eq(cluster, accented)
    end
  end
end

T["wrap"]["palavra mais larga que a linha é partida em pedaços"] = function()
  local lines = r(string.rep("a", 50), { width = 20 }).lines
  eq(vim.tbl_map(cells, lines), { 20, 20, 10 })
  eq(table.concat(lines), string.rep("a", 50))
end

T["wrap"]["URL comprida no meio do texto vai inteira para a linha seguinte se cabe"] = function()
  local lines = r("veja http://exemplo.com/caminho agora", { width = 28 }).lines
  eq(lines, { "veja", "http://exemplo.com/caminho", "agora" })
end

T["wrap"]["espaços colapsam e não sobram nas pontas"] = function()
  local lines = inline.layout({ { kind = "text", text = "  a   b \t c  " } }, 40)
  eq(lines, { "a b c" })
end

T["wrap"]["quebra suave é espaço e quebra forçada é nova linha"] = function()
  eq(inline.layout({ { kind = "text", text = "a\nb" } }, 40), { "a b" })
  eq(
    inline.layout(
      { { kind = "text", text = "a" }, { kind = "break" }, { kind = "text", text = "b" } },
      40
    ),
    { "a", "b" }
  )
  eq(r("a  \nb").lines, { "a", "b" })
  -- Quebra forçada no fim não deixa linha vazia sobrando.
  eq(inline.layout({ { kind = "text", text = "a" }, { kind = "break" } }, 40), { "a" })
end

T["wrap"]["spans vazios dão uma linha vazia"] = function()
  eq(inline.layout({}, 40), { "" })
end

-- ---------------------------------------------------------------------------------------
-- Spans inline
-- ---------------------------------------------------------------------------------------

T["inline"] = new_set()

T["inline"]["negrito, itálico, código e link ganham marca com o texto exato"] = function()
  local result = r("um **negrito**, um *itálico*, `código` e [link](http://x.y)")
  eq(marked(result, "DeckleStrong"), { "negrito" })
  eq(marked(result, "DeckleEmphasis"), { "itálico" })
  eq(marked(result, "DeckleCodeInline"), { "código" })
  eq(marked(result, "DeckleLink"), { "link" })
  eq(result.lines[1]:find("http", 1, true), nil)
end

T["inline"]["spans aninhados empilham marcas"] = function()
  local result = r("**a *b* c**")
  eq(marked(result, "DeckleStrong"), { "a b c" })
  eq(marked(result, "DeckleEmphasis"), { "b" })
end

T["inline"]["as marcas são em bytes: texto multibyte antes não as desloca"] = function()
  local result = r("😀 ñandú 日本 **negrito**")
  eq(marked(result, "DeckleStrong"), { "negrito" })
  eq(mark_problems(result), {})
end

T["inline"]["espaço entre dois trechos de mesmo estilo entra na marca; entre dois estilos, não"] = function()
  eq(marked(r("**um dois** três"), "DeckleStrong"), { "um dois" })
  eq(marked(r("**um** **dois**"), "DeckleStrong"), { "um", "dois" })
end

T["inline"]["marca que atravessa a quebra vira uma marca por linha"] = function()
  local result = r("**um dois três quatro cinco seis sete oito**", { width = 15 })
  eq(#result.lines > 1, true)
  eq(marked(result, "DeckleStrong"), result.lines)
  for _, mark in ipairs(result.marks) do
    eq(mark.col, 0)
  end
end

T["inline"]["imagem vira texto alternativo"] = function()
  local result = r("antes ![logo](a.png) depois")
  eq(result.lines, { "antes [image: logo] depois" })
  eq(marked(result, "DeckleImage"), { "[image: logo]" })
  eq(r("![](a.png)").lines, { "[image]" })
end

T["inline"]["selo (imagem dentro de link) leva as duas marcas"] = function()
  local result = r("[![build](b.svg)](http://ci)")
  eq(result.lines, { "[image: build]" })
  eq(marked(result, "DeckleLink"), { "[image: build]" })
  eq(marked(result, "DeckleImage"), { "[image: build]" })
end

T["inline"]["link sem texto mostra o destino"] = function()
  local lines, marks = inline.layout({ { kind = "link", href = "http://x.y", children = {} } }, 40)
  eq(lines, { "http://x.y" })
  eq(marks[1].hl, "DeckleLink")
end

T["inline"]["controle vira espaço e não entra na conta de largura"] = function()
  eq(inline.layout({ { kind = "text", text = "a\tb\rc\0d" } }, 40), { "a b c d" })
end

-- ---------------------------------------------------------------------------------------
-- heading
-- ---------------------------------------------------------------------------------------

T["heading"] = new_set()

T["heading"]["cada nível tem o seu grupo, na linha toda"] = function()
  for level = 1, 6 do
    local result = r(string.rep("#", level) .. " Título")
    eq(marked(result, "DeckleH" .. level)[1], "Título")
  end
end

T["heading"]["H1 e H2 têm sublinhado; H3 em diante, não"] = function()
  eq(r("# Título").lines, { "Título", "══════" })
  eq(r("## Título").lines, { "Título", "──────" })
  eq(r("### Título").lines, { "Título" })
  eq(r("###### Título").lines, { "Título" })
end

T["heading"]["sublinhado ASCII"] = function()
  eq(r("# Título", { charset = "ascii" }).lines, { "Título", "======" })
  eq(r("## Título", { charset = "ascii" }).lines, { "Título", "------" })
end

T["heading"]["o sublinhado tem a largura de display da linha mais larga"] = function()
  local lines = r("# 日本語 😀").lines
  eq(cells(lines[1]), 9)
  eq(cells(lines[2]), 9)
  local wrapped = r("# um dois três quatro cinco seis sete oito nove dez", { width = 20 }).lines
  eq(cells(wrapped[#wrapped]), widest(vim.list_slice(wrapped, 1, #wrapped - 1)))
end

T["heading"]["título comprido quebra e mantém a marca em todas as linhas"] = function()
  local result =
    r("### um dois três quatro cinco seis sete oito nove dez onze doze", { width = 20 })
  eq(widest(result.lines) <= 20, true)
  eq(marked(result, "DeckleH3"), result.lines)
end

T["heading"]["setext vira o mesmo que ATX"] = function()
  eq(r("Título\n======").lines, r("# Título").lines)
end

-- ---------------------------------------------------------------------------------------
-- list
-- ---------------------------------------------------------------------------------------

T["list"] = new_set()

T["list"]["marcador muda a cada nível, em ciclo"] = function()
  local text = "- a\n  - b\n    - c\n      - d"
  eq(r(text).lines, { "• a", "  ◦ b", "    ▪ c", "      • d" })
  eq(r(text, { charset = "ascii" }).lines, { "- a", "  * b", "    + c", "      - d" })
end

T["list"]["recuo suspenso: a continuação alinha com o texto"] = function()
  local lines = r("- um dois três quatro cinco seis sete oito nove dez", { width = 20 }).lines
  eq(widest(lines) <= 20, true)
  eq(lines[1]:sub(1, 6), "• um")
  for i = 2, #lines do
    eq(lines[i]:sub(1, 2), "  ")
    eq(lines[i]:sub(3, 3) ~= " ", true)
  end
end

T["list"]["lista ordenada: começa no número do fonte e alinha pelo maior"] = function()
  eq(r("1. a\n2. b").lines, { "1. a", "2. b" })
  eq(r("9. a\n10. b\n11. c").lines, { " 9. a", "10. b", "11. c" })
  eq(r("5) a\n6) b").lines, { "5. a", "6. b" })
end

T["list"]["texto de item ordenado quebra alinhado depois do número"] = function()
  local lines = r("10. um dois três quatro cinco seis sete oito nove dez", { width = 22 }).lines
  eq(widest(lines) <= 22, true)
  eq(lines[1]:sub(1, 4), "10. ")
  eq(lines[2]:sub(1, 4), "    ")
end

T["list"]["item de tarefa troca o marcador"] = function()
  eq(r("- [ ] a\n- [x] b").lines, { "☐ a", "☑ b" })
  eq(r("- [ ] a\n- [x] b", { charset = "ascii" }).lines, { "[ ] a", "[x] b" })
  eq(r("1. [x] a", { charset = "ascii" }).lines, { "1. [x] a" })
end

T["list"]["sublista cola no item; outro filho tem uma linha em branco antes"] = function()
  eq(r("- a\n  - b").lines, { "• a", "  ◦ b" })
  eq(r("- a\n\n  mais texto\n\n  - b").lines, { "• a", "", "  mais texto", "  ◦ b" })
end

T["list"]["item aberto por bloco de código não tem linha de texto antes"] = function()
  eq(r("- ```\n  codigo\n  ```").lines, { "• codigo" })
end

T["list"]["item vazio mostra só o marcador"] = function()
  eq(r("-\n- b").lines, { "•", "• b" })
end

T["list"]["item com CJK e emoji respeita a largura"] = function()
  local lines = r("- " .. string.rep("日本語😀", 8), { width = 20 }).lines
  eq(widest(lines) <= 20, true)
  eq(#lines > 1, true)
end

T["list"]["marca do marcador cobre só o marcador"] = function()
  local result = r("- a\n  - b\n1. c")
  eq(marked(result, "DeckleBullet"), { "•", "◦", "1." })
end

-- ---------------------------------------------------------------------------------------
-- quote
-- ---------------------------------------------------------------------------------------

T["quote"] = new_set()

T["quote"]["borda em toda linha, inclusive a em branco, sem espaço sobrando"] = function()
  local result = r("> um\n>\n> dois")
  eq(result.lines, { "│ um", "│", "│ dois" })
  eq(marked(result, "DeckleQuote"), { "│", "│", "│" })
end

T["quote"]["borda ASCII"] = function()
  eq(r("> um\n>\n> dois", { charset = "ascii" }).lines, { "| um", "|", "| dois" })
end

T["quote"]["quote dentro de quote"] = function()
  local result = r("> a\n>\n> > b")
  eq(result.lines, { "│ a", "│", "│ │ b" })
  eq(#marked(result, "DeckleQuote"), 4)
  eq(mark_problems(result), {})
end

T["quote"]["texto comprido quebra na largura menos a borda"] = function()
  local lines = r("> " .. string.rep("palavra ", 20), { width = 30 }).lines
  eq(widest(lines) <= 30, true)
  eq(#lines > 3, true)
  for _, line in ipairs(lines) do
    eq(line:sub(1, 6), "│ pa")
  end
end

T["quote"]["quote vazio ocupa uma linha"] = function()
  eq(r(">").lines, { "│" })
end

T["quote"]["lista e negrito dentro do quote ficam deslocados pela borda"] = function()
  local result = r("> - **a**\n> - b")
  eq(result.lines, { "│ • a", "│ • b" })
  eq(marked(result, "DeckleStrong"), { "a" })
  eq(marked(result, "DeckleBullet"), { "•", "•" })
end

T["quote"]["aninhamento fundo não lança e o conteúdo sobrevive"] = function()
  local result = r(string.rep("> ", 20) .. "texto")
  eq(result.lines[#result.lines]:match("texto$"), "texto")
  eq(mark_problems(result), {})
end

-- ---------------------------------------------------------------------------------------
-- rule
-- ---------------------------------------------------------------------------------------

T["rule"] = new_set()

T["rule"]["ocupa a largura inteira"] = function()
  local result = r("---", { width = 25 })
  eq(result.lines, { string.rep("─", 25) })
  eq(marked(result, "DeckleRule"), result.lines)
  eq(r("---", { width = 25, charset = "ascii" }).lines, { string.rep("-", 25) })
end

T["rule"]["dentro de contêiner ocupa só o que sobrou"] = function()
  eq(r("> ---", { width = 20 }).lines, { "│ " .. string.rep("─", 18) })
  -- `- ---` seria uma regra (CommonMark), não um item: a regra vem como filho do item.
  eq(r("- a\n\n  ---", { width = 20 }).lines, { "• a", "", "  " .. string.rep("─", 18) })
end

T["rule"]["com ambiwidth=double o glifo ocupa duas células e a regra continua na largura"] = function()
  local saved = vim.o.ambiwidth
  local ok = pcall(function()
    vim.o.ambiwidth = "double"
  end)
  if not ok then
    -- O Neovim recusa `double` com algum `fillchars`/`listchars` ambíguo nesta máquina. Sem
    -- como medir, o caso não vale: a divisão por `strdisplaywidth` do glifo está no código.
    return
  end
  local lines = r("---", { width = 20 }).lines
  local measured = cells(lines[1])
  vim.o.ambiwidth = saved
  eq(measured, 20)
  eq(#lines[1], 30) -- dez glifos de 3 bytes
end

-- ---------------------------------------------------------------------------------------
-- charset
-- ---------------------------------------------------------------------------------------

T["charset"] = new_set()

T["charset"]["ascii não emite um byte fora do ASCII"] = function()
  local text = table.concat({
    "# H1",
    "",
    "## H2",
    "",
    "texto simples",
    "",
    "- a",
    "  - b",
    "    - c",
    "- [ ] d",
    "- [x] e",
    "",
    "> citacao",
    "> > fundo",
    "",
    "---",
  }, "\n")
  local lines = r(text, { charset = "ascii" }).lines
  eq(table.concat(lines, "\n"):find("[\128-\255]"), nil)
  -- E o mesmo texto em Unicode tem que ter byte fora do ASCII, ou o teste acima é vazio.
  eq(table.concat(r(text).lines, "\n"):find("[\128-\255]") ~= nil, true)
end

T["charset"]["auto vira unicode, salvo TERM linux ou dumb"] = function()
  local saved = vim.env.TERM
  local ok, err = pcall(function()
    vim.env.TERM = "xterm-256color"
    eq(render.resolve_charset("auto"), "unicode")
    eq(render.resolve_charset(nil), "unicode")
    vim.env.TERM = "linux"
    eq(render.resolve_charset("auto"), "ascii")
    vim.env.TERM = "dumb"
    eq(render.resolve_charset("auto"), "ascii")
    -- O que o usuário pediu explicitamente vence a heurística.
    eq(render.resolve_charset("unicode"), "unicode")
    vim.env.TERM = "xterm-256color"
    eq(render.resolve_charset("ascii"), "ascii")
  end)
  vim.env.TERM = saved
  if not ok then
    error(err, 0)
  end
end

T["charset"]["auto é o que o render usa quando o charset não vem"] = function()
  local saved = vim.env.TERM
  vim.env.TERM = "dumb"
  local ok, lines = pcall(function()
    return render.render(parse.parse_lines("- a"), { width = 20 }).lines
  end)
  vim.env.TERM = saved
  eq(ok, true)
  eq(lines, { "- a" })
end

-- ---------------------------------------------------------------------------------------
-- Grupos de highlight
-- ---------------------------------------------------------------------------------------

T["highlights"] = new_set()

T["highlights"]["todo grupo que o código de render escreve está definido em deckle.highlight"] = function()
  local defined = require("deckle.highlight").groups
  local root = vim.fn.fnamemodify(tests_dir, ":h") .. "/lua/deckle/render"
  local used = {}
  for _, path in ipairs(vim.fn.globpath(root, "*.lua", false, true)) do
    for _, line in ipairs(vim.fn.readfile(path)) do
      for name in line:gmatch('"(Deckle%w+)"') do
        -- `"DeckleH" .. level`: o prefixo dos seis níveis de título.
        if name == "DeckleH" then
          for level = 1, 6 do
            used["DeckleH" .. level] = true
          end
        else
          used[name] = true
        end
      end
    end
  end
  eq(vim.tbl_count(used) >= 16, true)
  for name in pairs(used) do
    eq({ name, defined[name] ~= nil }, { name, true })
  end
end

T["highlights"]["todo grupo definido é default, para o esquema do usuário vencer"] = function()
  vim.api.nvim_set_hl(0, "DeckleH3", { fg = 0x00ff00 })
  local saved = vim.api.nvim_get_hl(0, { name = "DeckleH3" })
  require("deckle.highlight").setup()
  eq(vim.api.nvim_get_hl(0, { name = "DeckleH3" }), saved)
  for name in pairs(require("deckle.highlight").groups) do
    eq(vim.fn.hlexists(name), 1)
  end
end

-- ---------------------------------------------------------------------------------------
-- Fallbacks de code, table e html (fases 4 e 5 trocam os módulos)
-- ---------------------------------------------------------------------------------------

T["fallbacks"] = new_set()

T["fallbacks"]["code: linhas cruas, sem wrap, com marca"] = function()
  local long = string.rep("x", 60)
  local result = r("```lua\nlocal a = 1\n\n    " .. long .. "\n```", { width = 20 })
  eq(result.lines, { "local a = 1", "", "    " .. long })
  eq(marked(result, "DeckleCode"), { "local a = 1", "    " .. long })
end

T["fallbacks"]["code: bloco vazio e bloco sem info string não lançam"] = function()
  eq(r("```\n```").lines, {})
  eq(r("```\nx\n```").lines, { "x" })
end

T["fallbacks"]["html: linhas cruas"] = function()
  local result = r("<div>\n  oi\n</div>")
  eq(result.lines, { "<div>", "  oi", "</div>" })
  eq(marked(result, "DeckleHtml"), result.lines)
end

-- ---------------------------------------------------------------------------------------
-- Mapa
-- ---------------------------------------------------------------------------------------

T["mapa"] = new_set()

T["mapa"]["um por bloco de topo, ordenado, com os índices do fonte"] = function()
  local text = "# a\n\npar um\npar dois\n\n- x\n- y\n\n---\n\n> q"
  local ir = parse.parse_lines(text)
  local result = render.render(ir, { width = 40, charset = "unicode" })
  eq(#result.map, 5)
  eq(map_problems(ir, result), {})
  eq(result.map[1], { preview_start = 0, preview_end = 2, src_start = 0, src_end = 1 })
  eq(result.map[2], { preview_start = 3, preview_end = 4, src_start = 2, src_end = 4 })
  eq(result.map[3], { preview_start = 5, preview_end = 7, src_start = 5, src_end = 7 })
end

T["mapa"]["bloco de N linhas no preview mapeia para o intervalo dele no fonte"] = function()
  -- Um parágrafo de uma linha no fonte que vira várias no preview.
  local ir = parse.parse_lines("# t\n\n" .. string.rep("palavra ", 30))
  local result = render.render(ir, { width = 20, charset = "unicode" })
  local entry = result.map[2]
  eq(entry.src_end - entry.src_start, 1)
  eq(entry.preview_end - entry.preview_start > 3, true)
end

T["mapa"]["bloco que não produz linha some, sem linha em branco e sem entrada"] = function()
  local ir = {
    { kind = "paragraph", spans = { { kind = "text", text = "a" } }, src_start = 0, src_end = 1 },
    { kind = "code", lines = {}, src_start = 2, src_end = 4 },
    { kind = "paragraph", spans = { { kind = "text", text = "b" } }, src_start = 5, src_end = 6 },
  }
  local result = render.render(ir, { width = 40 })
  eq(result.lines, { "a", "", "b" })
  eq(#result.map, 2)
  eq(map_problems({ ir[1], ir[3] }, result), {})
end

-- ---------------------------------------------------------------------------------------
-- Invariantes sobre o que o parser já tem de fixture
-- ---------------------------------------------------------------------------------------

T["invariantes"] = new_set()

for _, name in ipairs({
  "headings",
  "inline",
  "lists",
  "quote_code",
  "tables",
  "misc",
  "unclosed",
  "nested",
  "slices",
}) do
  T["invariantes"]["fixture " .. name .. " em várias larguras"] = function()
    local ir = parse.parse_lines(H.read_fixture(name))
    for _, width in ipairs({ 1, 12, 33, 80, 200 }) do
      for _, charset in ipairs({ "unicode", "ascii" }) do
        render.last_error = nil
        local result = render.render(ir, { width = width, charset = charset })
        eq(render.last_error, nil)
        eq(mark_problems(result), {})
        eq(map_problems(ir, result), {})
        for _, line in ipairs(result.lines) do
          eq(line:find("\n", 1, true), nil)
        end
      end
    end
  end
end

T["invariantes"]["o README do projeto renderiza sem erro em várias larguras"] = function()
  local readme = vim.fn.fnamemodify(tests_dir, ":h") .. "/README.md"
  local ir = parse.parse_lines(vim.fn.readfile(readme))
  eq(#ir > 5, true)
  for _, width in ipairs({ 10, 40, 80, 160 }) do
    render.last_error = nil
    local result = render.render(ir, { width = width, charset = "auto" })
    eq(render.last_error, nil)
    eq(#result.lines > 20, true)
    eq(mark_problems(result), {})
    eq(map_problems(ir, result), {})
  end
end

T["invariantes"]["parágrafos nunca passam da largura, com emoji e CJK de qualquer jeito"] = function()
  local pieces = {
    "palavra",
    "😀",
    "日本語",
    "ñandú",
    "a",
    "👨‍👩‍👧",
    "x" .. string.rep("y", 25),
    "é",
  }
  local seed = 7
  for width = 10, 40, 3 do
    local doc = {}
    for _ = 1, 60 do
      seed = (seed * 1103515245 + 12345) % 2147483648
      doc[#doc + 1] = pieces[(math.floor(seed / 65536) % #pieces) + 1]
      seed = (seed * 1103515245 + 12345) % 2147483648
      if math.floor(seed / 65536) % 3 > 0 then
        doc[#doc + 1] = " "
      end
    end
    local lines = r(table.concat(doc), { width = width }).lines
    eq(widest(lines) <= width, true)
  end
end

return T
