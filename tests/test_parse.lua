-- Testes de `deckle.parse` (fase 1). Um bloco por item do gate de saída:
--
--   1. fixtures `tests/fixtures/*.md` contra o IR esperado em `tests/fixtures/*.lua`;
--   2. aninhamento patológico não derruba o processo nem estoura a pilha;
--   3. arquivo vazio e de uma linha produzem IR válido;
--   4. `src_start`/`src_end` de todo bloco batem com o texto real do fonte.
--
-- Mais os caminhos de degradação de ADR-0004, cada um forçado (parser escondido, parser
-- inline ausente), e o contrato de que o buffer fonte não é tocado (ADR-0003).
--
-- Snapshot é gerado, não escrito à mão. Depois de mudar o IR de propósito:
--
--   DECKLE_UPDATE_SNAPSHOTS=1 ./scripts/test.sh tests/test_parse.lua
--   stylua tests/
--
-- e LEIA o diff dos `tests/fixtures/*.lua` antes de commitar: um snapshot regenerado sem
-- revisão aprova qualquer bug.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h")
local helpers_path = tests_dir .. "/helpers.lua"
local H = dofile(helpers_path)

local parse = require("deckle.parse")

local FIXTURES = {
  "headings",
  "inline",
  "lists",
  "quote_code",
  "tables",
  "misc",
  "unclosed",
  "nested",
  "slices",
}

local child = MiniTest.new_child_neovim()

---@type integer[]
local buffers = {}

---@param lines string[]
---@return integer
local function scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  buffers[#buffers + 1] = buf
  return buf
end

---@param names string[]
---@return table[]
local function params(names)
  return vim.tbl_map(function(name)
    return { name }
  end, names)
end

local T = new_set({
  hooks = {
    post_case = function()
      for _, buf in ipairs(buffers) do
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      buffers = {}
    end,
  },
})

-- ---------------------------------------------------------------------------------------
-- Gate 1: fixtures e snapshots
-- ---------------------------------------------------------------------------------------

T["fixtures"] = new_set({ parametrize = params(FIXTURES) })

T["fixtures"]["o IR bate com o snapshot"] = function(name)
  local ir = parse.parse_lines(H.read_fixture(name))
  eq(parse.last_error, nil)

  local snapshot = H.fixtures_dir .. "/" .. name .. ".lua"
  if vim.env.DECKLE_UPDATE_SNAPSHOTS == "1" then
    vim.fn.writefile(vim.split("return " .. H.serialize(ir), "\n", { plain = true }), snapshot)
    return
  end
  eq(ir, dofile(snapshot))
end

T["fixtures"]["parsear pelo buffer dá o mesmo IR que pelas linhas"] = function(name)
  local lines = H.read_fixture(name)
  eq(parse.parse(scratch(lines)), parse.parse_lines(lines))
end

T["fixtures"]["parsear de texto dá o mesmo IR que de linhas"] = function(name)
  local lines = H.read_fixture(name)
  eq(parse.parse_lines(table.concat(lines, "\n") .. "\n"), parse.parse_lines(lines))
end

-- ---------------------------------------------------------------------------------------
-- Gate 4: os intervalos batem com o fonte
-- ---------------------------------------------------------------------------------------

T["intervalos"] = new_set({ parametrize = params(FIXTURES) })

T["intervalos"]["todo bloco, item e filho bate com o fonte, e tem o formato do seu tipo"] = function(
  name
)
  local lines = H.read_fixture(name)
  eq(H.check(lines, parse.parse_lines(lines), true), {})
end

T["intervalos"]["recortar o buffer pelas linhas devolve o texto do bloco"] = function()
  local buf = scratch(H.read_fixture("slices"))
  local got = {}
  for _, block in ipairs(parse.parse(buf)) do
    local rows = vim.api.nvim_buf_get_lines(buf, block.src_start, block.src_end, false)
    got[#got + 1] = { block.kind, table.concat(rows, "\n") }
  end

  eq(got, {
    { "heading", "# Título" },
    { "paragraph", "Primeira linha\nsegunda linha" },
    { "list", "- item um\n  continuação do item\n- item dois\n  - sub item" },
    { "quote", "> citação\n> em duas linhas" },
    { "code", "```lua\nlocal x = 1\n```" },
    { "code", "    indentado" },
    { "table", "| a | b |\n|---|---|\n| 1 | 2 |" },
    { "rule", "---" },
    { "html", "<div>\nhtml\n</div>" },
    { "heading", "Setext\n------" },
  })
end

T["intervalos"]["itens de lista e filhos de quote também recortam certo"] = function()
  local buf = scratch(H.read_fixture("slices"))
  local list = parse.parse(buf)[3]
  local items = {}
  for _, item in ipairs(list.items) do
    local rows = vim.api.nvim_buf_get_lines(buf, item.src_start, item.src_end, false)
    items[#items + 1] = table.concat(rows, "\n")
  end
  eq(items, { "- item um\n  continuação do item", "- item dois\n  - sub item" })

  local sub = list.items[2].children[1]
  eq(sub.kind, "list")
  eq(vim.api.nvim_buf_get_lines(buf, sub.src_start, sub.src_end, false), { "  - sub item" })
end

T["intervalos"]["linha em branco final do treesitter não entra no bloco"] = function()
  -- O treesitter fecha lista, html e código indentado depois da linha em branco.
  local lines = { "- a", "- b", "", "<p>", "x", "", "    c", "", "fim" }
  local blocks = parse.parse_lines(lines)
  local ranges = {}
  for _, block in ipairs(blocks) do
    ranges[#ranges + 1] = { block.kind, block.src_start, block.src_end }
  end
  eq(ranges, { { "list", 0, 2 }, { "html", 3, 5 }, { "code", 6, 7 }, { "paragraph", 8, 9 } })
end

T["intervalos"]["`>` solto no fim do quote fica de fora"] = function()
  local blocks = parse.parse_lines({ "> a", ">", "", "texto" })
  eq({ blocks[1].kind, blocks[1].src_start, blocks[1].src_end }, { "quote", 0, 1 })
end

T["intervalos"]["quote vazio aninhado no fim continua dentro do pai"] = function()
  -- O corte de `>` soltos no fim do pai não pode deixar o filho que mora nessa linha de fora.
  local lines = { "> > a", "> > >", "", "texto" }
  eq(H.check(lines, parse.parse_lines(lines), false), {})
end

T["fuzz"] = new_set()

--- Documentos aleatórios, sempre os mesmos (gerador com semente). Rodam num filho: se o
--- treesitter abortar com alguma combinação que ninguém previu, morre o filho e o teste
--- falha, em vez de derrubar a suíte.
T["fuzz"]["600 documentos aleatórios parseiam sem lançar, sem erro engolido e com intervalos coerentes"] = function()
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.lua(string.format("_G.H = dofile(%q)", helpers_path))
  eq(child.lua_get([[table.concat(H.fuzz(300, 20260117), "\n\n")]]), "")
  eq(child.lua_get([[table.concat(H.fuzz(300, 7), "\n\n")]]), "")
  eq(child.lua_get("1 + 1"), 2) -- o filho sobreviveu
  child.stop()
end

-- ---------------------------------------------------------------------------------------
-- Gate 3: vazio e uma linha
-- ---------------------------------------------------------------------------------------

T["vazio"] = new_set()

T["vazio"]["entrada sem conteúdo dá IR vazio"] = function()
  eq(parse.parse_lines({}), {})
  eq(parse.parse_lines({ "" }), {})
  eq(parse.parse_lines(""), {})
  eq(parse.parse_lines("\n\n"), {})
  eq(parse.parse_lines({ "", "   ", "\t", "" }), {})
  eq(parse.parse(scratch({})), {})
end

T["vazio"]["buffer inválido dá IR vazio, não erro"] = function()
  eq(parse.parse(987654), {})
end

T["vazio"]["`parse()` sem argumento lê o buffer atual"] = function()
  local buf = scratch({ "# atual" })
  local previous = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(buf)
  local blocks = parse.parse()
  vim.api.nvim_set_current_buf(previous)
  eq(#blocks, 1)
  eq(blocks[1].kind, "heading")
end

local ONE_LINERS = {
  "texto",
  "# título",
  "## título ##",
  "- item",
  "1. item",
  "> citação",
  "```",
  "```lua",
  "---",
  "***",
  "<div>",
  "    código",
  "| a | b |",
  "[r]: http://x",
  "\\",
  "`",
  "**",
  "![](",
  "[",
  "|",
  ">",
  "-",
  "#",
  "日本語",
  "😀",
}

T["uma linha"] = new_set({ parametrize = params(ONE_LINERS) })

T["uma linha"]["produz IR válido, com ou sem quebra de linha final"] = function(text)
  local blocks = parse.parse_lines({ text })
  eq(parse.last_error, nil)
  eq(H.check({ text }, blocks, false), {})
  eq(parse.parse_lines(text), blocks)
  eq(parse.parse_lines(text .. "\n"), blocks)
end

T["uma linha"]["quando tem conteúdo, o único bloco cobre a linha 0"] = function(text)
  local blocks = parse.parse_lines({ text })
  -- `[r]: ...` é definição e não gera bloco; o resto gera ao menos um.
  if text:match("^%[r%]:") then
    eq(blocks, {})
    return
  end
  eq(#blocks >= 1, true)
  eq(blocks[1].src_start, 0)
  eq(blocks[#blocks].src_end, 1)
end

T["uma linha"]["os tipos conhecidos saem com o `kind` certo"] = function()
  local function kind_of(text)
    return parse.parse_lines({ text })[1].kind
  end
  eq(kind_of("# título"), "heading")
  eq(kind_of("texto"), "paragraph")
  eq(kind_of("- item"), "list")
  eq(kind_of("1. item"), "list")
  eq(kind_of("> citação"), "quote")
  eq(kind_of("```"), "code")
  eq(kind_of("    código"), "code")
  eq(kind_of("---"), "rule")
  eq(kind_of("<div>"), "html")
end

-- ---------------------------------------------------------------------------------------
-- Gate 2: aninhamento patológico
-- ---------------------------------------------------------------------------------------

-- Medido em docs/validation.md (V6): o scanner de Markdown aborta o processo com mais de
-- ~200 contêineres abertos. Sem a guarda de `parse.lua`, estes casos matam o filho e o teste
-- falha por "Neovim process died". Rodam num filho por isso.
local PATHOLOGICAL = [[
  _G.parse = require("deckle.parse")

  function _G.shape(name, n)
    local lines = {}
    if name == "lista-em-quote" then
      lines[1] = string.rep("- > ", n) .. "x"
    elseif name == "quote" then
      lines[1] = string.rep("> ", n) .. "x"
    elseif name == "lista" then
      lines[1] = string.rep("- ", n) .. "x"
    elseif name == "lista-por-recuo" then
      for k = 0, n - 1 do
        lines[#lines + 1] = string.rep("  ", k) .. "- x"
      end
    elseif name == "ordenada-por-recuo" then
      for k = 0, n - 1 do
        lines[#lines + 1] = string.rep("   ", k) .. "1. x"
      end
    elseif name == "quote-por-linha" then
      for k = 1, n do
        lines[#lines + 1] = string.rep("> ", k) .. "x"
      end
    elseif name == "quote-de-lista-por-linha" then
      for k = 0, n - 1 do
        lines[#lines + 1] = string.rep("> ", k) .. "- x"
      end
    end
    return lines
  end

  -- Quantos contêineres (quote, lista) há na cadeia mais funda do IR.
  function _G.depth_of(blocks)
    local deepest = 0
    for _, block in ipairs(blocks) do
      local depth = 0
      if block.kind == "quote" then
        depth = 1 + _G.depth_of(block.children)
      elseif block.kind == "list" then
        for _, item in ipairs(block.items) do
          depth = math.max(depth, 1 + _G.depth_of(item.children))
        end
      end
      deepest = math.max(deepest, depth)
    end
    return deepest
  end

  function _G.summary(lines)
    local blocks = parse.parse_lines(lines)
    local kinds = {}
    for i, block in ipairs(blocks) do
      kinds[i] = block.kind
    end
    return {
      kinds = kinds,
      depth = _G.depth_of(blocks),
      last_end = blocks[#blocks] and blocks[#blocks].src_end or -1,
      nlines = #lines,
      problems = table.concat(H.check(lines, blocks, false), "\n"),
      last_error = parse.last_error or false,
    }
  end
]]

local patho_hooks = {
  pre_case = function()
    child.restart({ "-u", "tests/minimal_init.lua" })
    child.lua(string.format("_G.H = dofile(%q)", helpers_path))
    child.lua(PATHOLOGICAL)
  end,
  post_once = child.stop,
}

--- Formas que, sem a guarda, abortam o processo (exit 134).
local ABORTING = {
  { "lista-em-quote", 300 },
  { "lista-em-quote", 5000 },
  { "quote", 1000 },
  { "quote", 200000 },
  { "lista", 1000 },
  { "lista-por-recuo", 300 },
  { "ordenada-por-recuo", 300 },
  { "quote-por-linha", 300 },
  { "quote-de-lista-por-linha", 300 },
}

T["aninhamento patológico: além da guarda"] = new_set({
  hooks = patho_hooks,
  parametrize = ABORTING,
})

T["aninhamento patológico: além da guarda"]["cai no caminho cru e o processo sobrevive"] = function(
  shape,
  n
)
  -- Sem a guarda, o treesitter aborta aqui (exit 134) e o filho morre.
  local summary = child.lua_get(string.format("summary(shape(%q, %d))", shape, n))
  eq(child.lua_get("1 + 1"), 2)

  -- Sem linha em branco, o caminho cru devolve um parágrafo só, cobrindo tudo.
  eq(summary.kinds, { "paragraph" })
  eq(summary.last_end, summary.nlines)
  eq(summary.problems, "")
  eq(summary.last_error, false)
end

--- Fundo o bastante para passar da profundidade do IR, raso o bastante para passar pela
--- guarda (e pelo scanner).
T["aninhamento patológico: além de MAX_DEPTH"] = new_set({
  hooks = patho_hooks,
  parametrize = {
    { "quote", 50 },
    { "lista-em-quote", 20 },
    { "lista-por-recuo", 50 },
    { "quote-por-linha", 50 },
  },
})

T["aninhamento patológico: além de MAX_DEPTH"]["vira parágrafo cru e a recursão tem teto"] = function(
  shape,
  n
)
  local summary = child.lua_get(string.format("summary(shape(%q, %d))", shape, n))
  eq(child.lua_get("1 + 1"), 2)
  eq(summary.problems, "")
  eq(summary.last_error, false)
  eq(summary.depth, child.lua_get("parse.MAX_DEPTH"))
end

T["aninhamento patológico"] = new_set({ hooks = patho_hooks })

T["aninhamento patológico"]["aninhamento razoável passa pela guarda e vira IR de verdade"] = function()
  -- 10 níveis de lista por recuo: bem abaixo de MAX_NESTING e de MAX_DEPTH.
  local summary = child.lua_get([[summary(shape("lista-por-recuo", 10))]])
  eq(summary.kinds, { "list" })
  eq(summary.depth, 10)
  eq(summary.problems, "")
end

T["aninhamento patológico"]["a guarda não confunde recuo de código com aninhamento"] = function()
  local summary = child.lua_get([[summary({ string.rep(" ", 400) .. "texto recuado" })]])
  eq(summary.kinds, { "code" })
  eq(summary.problems, "")
end

T["aninhamento patológico"]["o caminho cru separa os trechos por linha em branco"] = function()
  child.lua([[
    _G.doc = { string.rep("> ", 300) .. "a", "mais", "", "", "outro" }
    _G.blocks = parse.parse_lines(_G.doc)
  ]])
  eq(child.lua_get("#blocks"), 2)
  eq(child.lua_get("{ blocks[1].src_start, blocks[1].src_end }"), { 0, 2 })
  eq(child.lua_get("{ blocks[2].src_start, blocks[2].src_end }"), { 4, 5 })
  eq(child.lua_get("blocks[2].spans[1].text"), "outro")
end

-- ---------------------------------------------------------------------------------------
-- Degradação (ADR-0004): cada caminho forçado
-- ---------------------------------------------------------------------------------------

local degrade = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.lua(string.format("_G.H = dofile(%q)", helpers_path))
      child.lua([[
        _G.parse = require("deckle.parse")
        _G.doc = { "# Título **forte**", "", "texto *solto*", "mais texto", "", "- item", "", "| a | b |", "|---|---|", "| 1 | 2 |" }
      ]])
    end,
    post_once = child.stop,
  },
})

T["degradação"] = degrade

degrade["parser `markdown` escondido: um parágrafo cru por trecho, e nada lança"] = function()
  child.lua([[
    local real = vim.treesitter.language.add
    vim.treesitter.language.add = function(lang, ...)
      if lang == "markdown" then
        error("no parser for 'markdown' language")
      end
      return real(lang, ...)
    end
    _G.blocks = parse.parse_lines(_G.doc)
  ]])

  eq(child.lua_get("#blocks"), 4)
  eq(
    child.lua_get("vim.tbl_map(function(b) return b.kind end, blocks)"),
    { "paragraph", "paragraph", "paragraph", "paragraph" }
  )
  eq(child.lua_get("blocks[2].spans[1].text"), "texto *solto*\nmais texto")
  eq(child.lua_get("{ blocks[2].src_start, blocks[2].src_end }"), { 2, 4 })
  eq(child.lua_get([[table.concat(H.check(_G.doc, blocks, false), "\n")]]), "")
  eq(child.lua_get("parse.last_error ~= nil"), true)
  eq(child.lua_get([[parse.last_error:find("no parser", 1, true) ~= nil]]), true)
end

degrade["erro inesperado no meio da construção: mesmo caminho cru"] = function()
  child.lua([[
    vim.treesitter.get_node_text = function()
      error("boom")
    end
    _G.blocks = parse.parse_lines({ "[r]: http://x", "", "texto" })
  ]])
  eq(child.lua_get("#blocks"), 2)
  eq(child.lua_get("blocks[1].spans[1].text"), "[r]: http://x")
  eq(child.lua_get([[parse.last_error:find("boom", 1, true) ~= nil]]), true)
end

degrade["parser `markdown_inline` ausente: a estrutura fica, o texto vira cru"] = function()
  child.lua([[
    local real = vim.treesitter.get_string_parser
    vim.treesitter.get_string_parser = function(...)
      local parser = real(...)
      parser.children = function()
        return {}
      end
      return parser
    end
    _G.blocks = parse.parse_lines(_G.doc)
  ]])

  eq(
    child.lua_get("vim.tbl_map(function(b) return b.kind end, blocks)"),
    { "heading", "paragraph", "list", "table" }
  )
  eq(child.lua_get("blocks[1].level"), 1)
  eq(child.lua_get("blocks[1].spans"), { { kind = "text", text = "Título **forte**" } })
  eq(child.lua_get("blocks[2].spans"), { { kind = "text", text = "texto *solto*\nmais texto" } })
  eq(child.lua_get("blocks[3].items[1].spans"), { { kind = "text", text = "item" } })
  eq(
    child.lua_get("blocks[4].header"),
    { { { kind = "text", text = "a" } }, { { kind = "text", text = "b" } } }
  )
  eq(child.lua_get([[table.concat(H.check(_G.doc, blocks, false), "\n")]]), "")
  eq(child.lua_get("parse.last_error == nil"), true)
end

degrade["depois de uma falha, a chamada seguinte volta a funcionar"] = function()
  child.lua([[
    local real = vim.treesitter.language.add
    vim.treesitter.language.add = function()
      error("no parser")
    end
    parse.parse_lines(_G.doc)
    _G.failed = parse.last_error ~= nil
    vim.treesitter.language.add = real
    _G.blocks = parse.parse_lines(_G.doc)
  ]])
  eq(child.lua_get("failed"), true)
  eq(child.lua_get("parse.last_error == nil"), true)
  eq(child.lua_get("blocks[1].kind"), "heading")
  eq(child.lua_get("blocks[1].spans[2].kind"), "strong")
end

-- ---------------------------------------------------------------------------------------
-- ADR-0003: o buffer fonte é intocável
-- ---------------------------------------------------------------------------------------

T["buffer fonte"] = new_set()

T["buffer fonte"]["parsear não modifica o buffer nem cria extmark ou namespace"] = function()
  local lines = H.read_fixture("inline")
  local buf = scratch(lines)

  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local namespaces = vim.api.nvim_get_namespaces()

  parse.parse(buf)
  parse.parse(buf)

  eq(vim.api.nvim_buf_get_changedtick(buf), tick)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
  eq(vim.bo[buf].modifiable, true)
  eq(vim.bo[buf].modified, false)
  eq(vim.api.nvim_get_namespaces(), namespaces)
  for _, ns in pairs(namespaces) do
    eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0)
  end
end

-- ---------------------------------------------------------------------------------------
-- Detalhes do IR
-- ---------------------------------------------------------------------------------------

T["detalhes"] = new_set()

T["detalhes"]["`align` tem buracos: use `#header` para o número de colunas"] = function()
  local table_block = parse.parse_lines({ "| a | b | c |", "|:--|---|--:|", "| 1 | 2 | 3 |" })[1]
  eq(#table_block.header, 3)
  eq(table_block.align[1], "left")
  eq(table_block.align[2], nil)
  eq(table_block.align[3], "right")
  eq(table_block.rows, {
    {
      { { kind = "text", text = "1" } },
      { { kind = "text", text = "2" } },
      { { kind = "text", text = "3" } },
    },
  })
end

T["detalhes"]["alinhamento ao centro, à esquerda e à direita, cada um"] = function()
  local blocks =
    parse.parse_lines({ "| a | b | c | d |", "|:-:|:--|--:|---|", "| 1 | 2 | 3 | 4 |" })
  local align = blocks[1].align
  eq({ align[1], align[2], align[3], align[4] }, { "center", "left", "right", nil })
end

T["detalhes"]["tabela sem corpo tem `rows` vazio, linha curta fica curta"] = function()
  local bare = parse.parse_lines({ "| a | b |", "|---|---|" })[1]
  eq(bare.kind, "table")
  eq(bare.rows, {})

  local ragged = parse.parse_lines({ "| a | b |", "|---|---|", "| só |" })[1]
  eq(#ragged.header, 2)
  eq(#ragged.rows[1], 1)
end

T["detalhes"]["célula vazia é uma lista de spans vazia"] = function()
  local blocks = parse.parse_lines({ "| a | b |", "|---|---|", "|   | x |" })
  eq(blocks[1].rows[1][1], {})
  eq(blocks[1].rows[1][2], { { kind = "text", text = "x" } })
end

T["detalhes"]["offsets de byte com emoji e CJK não deslocam os spans"] = function()
  local block = parse.parse_lines({ "日本語 **強調** 😀 *ñandú* `ü` fim" })[1]
  eq(block.spans, {
    { kind = "text", text = "日本語 " },
    { kind = "strong", children = { { kind = "text", text = "強調" } } },
    { kind = "text", text = " 😀 " },
    { kind = "emphasis", children = { { kind = "text", text = "ñandú" } } },
    { kind = "text", text = " " },
    { kind = "code", text = "ü" },
    { kind = "text", text = " fim" },
  })
  eq(parse.plain_text(block.spans), "日本語 強調 😀 ñandú ü fim")
end

T["detalhes"]["spans aninhados e `plain_text`"] = function()
  local block = parse.parse_lines({ "a **b *c* d** [e `f`](u) ![g](h)" })[1]
  eq(block.spans[2], {
    kind = "strong",
    children = {
      { kind = "text", text = "b " },
      { kind = "emphasis", children = { { kind = "text", text = "c" } } },
      { kind = "text", text = " d" },
    },
  })
  eq(parse.plain_text(block.spans), "a b c d e f g")
end

T["detalhes"]["link de referência resolve pela definição, venha ela antes ou depois"] = function()
  local after = parse.parse_lines({ "[a][R]", "", "[r]: http://depois" })
  eq(
    after[1].spans,
    { { kind = "link", href = "http://depois", children = { { kind = "text", text = "a" } } } }
  )
  eq(#after, 1) -- a definição não gera bloco

  local before = parse.parse_lines({ "[r]: http://antes", "", "[r] e [outro]" })
  eq(before[1].spans[1].href, "http://antes")
  eq(before[1].spans[2], { kind = "text", text = " e [outro]" })
end

T["detalhes"]["a primeira definição de um rótulo vence"] = function()
  -- Não usar `[x]` como rótulo: colide com a sintaxe de item de tarefa e o treesitter
  -- não o reconhece como definição.
  local blocks = parse.parse_lines({ "[rot]", "", "[rot]: http://um", "[ROT]: http://dois" })
  eq(blocks[1].spans[1].href, "http://um")
end

T["detalhes"]["quebra suave fica como \\n no texto, quebra forçada vira `break`"] = function()
  local block = parse.parse_lines({ "um", "dois  ", "três" })[1]
  eq(block.spans, {
    { kind = "text", text = "um\ndois" },
    { kind = "break" },
    { kind = "text", text = "três" },
  })
end

T["detalhes"]["prefixo de quote e de item não vaza para o texto de várias linhas"] = function()
  local quote = parse.parse_lines({ "> um", "> dois", "> três" })[1]
  eq(quote.children[1].spans, { { kind = "text", text = "um\ndois\ntrês" } })

  local list = parse.parse_lines({ "- um", "  dois", "  três" })[1]
  eq(list.items[1].spans, { { kind = "text", text = "um\ndois\ntrês" } })
end

T["detalhes"]["código: sem cerca, sem prefixo, recuo de 4 colunas ou 1 tab removido"] = function()
  local fenced = parse.parse_lines({ "> ```lua", "> local x = 1", ">", "> return x", "> ```" })[1]
  eq(fenced.children[1].lang, "lua")
  eq(fenced.children[1].lines, { "local x = 1", "", "return x" })

  eq(parse.parse_lines({ "    quatro", "      seis" })[1].lines, { "quatro", "  seis" })
  eq(parse.parse_lines({ "\ttab" })[1].lines, { "tab" })
end

T["detalhes"]["`lang` é só a primeira palavra do info string"] = function()
  eq(parse.parse_lines({ '```python title="x.py"', "1", "```" })[1].lang, "python")
  eq(parse.parse_lines({ "```", "1", "```" })[1].lang, nil)
end

T["detalhes"]["cerca sem fechamento não leva as linhas em branco finais"] = function()
  local block = parse.parse_lines({ "```", "a", "", "" })[1]
  eq(block.lines, { "a" })
  eq({ block.src_start, block.src_end }, { 0, 2 })
end

T["detalhes"]["lista: `ordered`, `start`, `checked`"] = function()
  local numbered = parse.parse_lines({ "7. a", "8. b" })[1]
  eq({ numbered.ordered, numbered.start }, { true, 7 })

  local paren = parse.parse_lines({ "2) a" })[1]
  eq({ paren.ordered, paren.start }, { true, 2 })

  local bullets = parse.parse_lines({ "- a", "- [ ] b", "- [x] c" })[1]
  eq({ bullets.ordered, bullets.start }, { false, nil })
  eq(
    { bullets.items[1].checked, bullets.items[2].checked, bullets.items[3].checked },
    { nil, false, true }
  )
end

T["detalhes"]["item que abre com bloco de código não tem spans"] = function()
  local list = parse.parse_lines({ "- ```", "  x", "  ```" })[1]
  eq(list.items[1].spans, {})
  eq(list.items[1].children[1].kind, "code")
end

T["detalhes"]["CRLF e quebra de linha dentro de um elemento não desalinham as linhas"] = function()
  eq(parse.parse_lines("# a\r\n\r\ntexto\r\n"), parse.parse_lines({ "# a", "", "texto" }))

  -- Um NUL no buffer chega como "\n". O índice de linha tem que continuar o do buffer.
  local blocks = parse.parse_lines({ "um\ndois", "", "três" })
  eq({ blocks[1].src_start, blocks[1].src_end }, { 0, 1 })
  eq({ blocks[2].src_start, blocks[2].src_end }, { 2, 3 })
end

T["detalhes"]["front matter cai no caminho de bloco desconhecido: parágrafo cru"] = function()
  local blocks = parse.parse_lines({ "---", "titulo: x", "---", "", "# Depois" })
  eq(blocks[1].kind, "paragraph")
  eq(blocks[1].spans, { { kind = "text", text = "---\ntitulo: x\n---" } })
  eq({ blocks[1].src_start, blocks[1].src_end }, { 0, 3 })
  eq(blocks[2].kind, "heading")
  eq(blocks[2].src_start, 4)
end

return T
