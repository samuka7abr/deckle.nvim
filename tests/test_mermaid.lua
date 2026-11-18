-- Testes de `deckle.render.mermaid` (fase 7): o módulo de tipo do bloco mermaid, o cache e a
-- degradação para código cru.
--
-- Nenhum caso exige o `.so`: o crate é um stub injetado em `package.loaded.deckle_native`, que o
-- `deckle.native` encontra no degrau do `require` antes de qualquer arquivo. A suíte inteira
-- roda igual no job `test` (sem Rust) e na máquina de quem tem `make native`. O que prova o
-- diagrama de verdade está em `tests/native/test_mermaid_native.lua`.
--
-- Todo caminho de degradação é forçado (ADR-0004): sem módulo (`native.path` quebrado e
-- `native.enabled = false`), erro de parse, diagrama grande demais, resposta inválida do
-- crate. O gate 2 (arquivo abre com o `.so` ausente) e o gate 3 (diagrama inválido degrada só
-- aquele bloco) são os casos de integração, num Neovim filho, no fim do arquivo.
--
-- O bloco degradado é o do `render/code.lua` (moldura e nota, fase 5). Os casos não dependem do
-- desenho da moldura: conferem que o texto do fonte está nas linhas, que a nota aparece uma vez
-- e que o contrato de chamada (`lang`, `lines`, `note`...) é o combinado. Os que checam a nota
-- inteira usam largura 100: o `code.lua` a corta na largura do bloco.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local parse = require("deckle.parse")
local render = require("deckle.render")
--- Sempre pelo `require`: `tests/test_config.lua` descarta `deckle.config` do `package.loaded`, e uma
--- referência guardada no começo do arquivo apontaria para a instância velha.
local function cfg()
  return require("deckle.config")
end
local native = require("deckle.native")
local mermaid = require("deckle.render.mermaid")

-- ---------------------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------------------

---@type { src: string, opts: table }[]
local calls = {}

--- O que o crate falso responde. Troque por caso: `fake.responder = function(src, opts) ... end`.
---@class deckle.test.Fake
---@field responder fun(src: string, opts: table): string[]
---@type deckle.test.Fake
local fake = { responder = nil }

--- Desenho padrão: uma caixa de três linhas com o fonte dentro. Erra como o crate real erra
--- (`error(msg, 0)`, string pura).
---@param src string
---@param opts table
---@return string[]
local function default_responder(src, opts)
  if src:find("INVALID", 1, true) then
    error("mermaid parse error: boom", 0)
  end
  if src == "" then
    error("empty mermaid source", 0)
  end
  local lines = vim.split(src, "\n", { plain = true })
  if #lines > opts.max_src_lines then
    error(
      ("mermaid source too large: %d lines exceeds the limit of %d (max_src_lines)"):format(
        #lines,
        opts.max_src_lines
      ),
      0
    )
  end
  return { "┌─┐", "│ " .. table.concat(lines, " / ") .. " │", "└─┘" }
end

local function use_stub()
  package.loaded.deckle_native = {
    render = function(src, opts)
      calls[#calls + 1] = { src = src, opts = vim.deepcopy(opts) }
      return fake.responder(src, opts)
    end,
    supported_types = function()
      return { "flowchart", "sequence" }
    end,
    version = function()
      return "0.0.0-stub"
    end,
  }
  native.reset()
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

local FENCE = "```mermaid\nflowchart TD\n  A --> B\n```"
local ART = { "┌─┐", "│ flowchart TD /   A --> B │", "└─┘" }

---@param lines string[]
---@param text string
---@return integer quantas linhas contêm `text`
local function count_in(lines, text)
  local n = 0
  for _, line in ipairs(lines) do
    if line:find(text, 1, true) then
      n = n + 1
    end
  end
  return n
end

---@param result deckle.RenderResult
---@param hl string
---@return integer
local function marks_of(result, hl)
  local n = 0
  for _, mark in ipairs(result.marks) do
    if mark.hl == hl then
      n = n + 1
    end
  end
  return n
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

---@param opts table
local function setup_native(opts)
  cfg().setup({ native = opts })
end

local saved

--- Estado de módulo que os casos mexem (config, cache, carregador) é guardado e devolvido.
local UNIT_HOOKS = {
  pre_case = function()
    saved = {
      loaded = package.loaded.deckle_native,
      options = vim.deepcopy(cfg().options),
      configured = cfg().configured,
      limit = mermaid.cache_limit,
    }
    calls = {}
    fake.responder = default_responder
    mermaid.cache_clear()
    mermaid.last_error = nil
    use_stub()
  end,
  post_case = function()
    package.loaded.deckle_native = saved.loaded
    cfg().options, cfg().configured = saved.options, saved.configured
    mermaid.cache_limit = saved.limit
    mermaid.cache_clear()
    native.reset()
  end,
}

---@return table
local function unit_set()
  return new_set({ hooks = UNIT_HOOKS })
end

local T = new_set()

-- ---------------------------------------------------------------------------------------
-- Com o módulo: o diagrama
-- ---------------------------------------------------------------------------------------

T["diagrama"] = unit_set()

T["diagrama"]["o bloco mermaid vira as linhas do crate, com a marca DeckleMermaid"] = function()
  local result = r(FENCE)
  eq(result.lines, ART)
  eq(#calls, 1)
  eq(calls[1].src, "flowchart TD\n  A --> B")
  -- Uma marca por linha, cobrindo a linha inteira em bytes.
  eq(marks_of(result, "DeckleMermaid"), 3)
  for _, mark in ipairs(result.marks) do
    eq(mark.col, 0)
    eq(mark.end_col, #result.lines[mark.row + 1])
  end
  -- Não há nota nem código cru.
  eq(count_in(result.lines, "mermaid: "), 0)
  eq(mermaid.last_error, nil)
end

T["diagrama"]["linha em branco do desenho fica sem marca"] = function()
  fake.responder = function()
    return { "┌─┐", "", "└─┘" }
  end
  local result = r(FENCE)
  eq(result.lines, { "┌─┐", "", "└─┘" })
  eq(marks_of(result, "DeckleMermaid"), 2)
end

T["diagrama"]["o mapa cobre o diagrama inteiro e aponta para as linhas da cerca"] = function()
  local result = r("antes\n\n" .. FENCE .. "\n\ndepois")
  eq(result.map, {
    { preview_start = 0, preview_end = 1, src_start = 0, src_end = 1 },
    { preview_start = 2, preview_end = 5, src_start = 2, src_end = 6 },
    { preview_start = 6, preview_end = 7, src_start = 7, src_end = 8 },
  })
end

T["diagrama"]["recebe a largura, o charset e max_src_lines que o render usa"] = function()
  r(FENCE, { width = 33, charset = "ascii" })
  eq(calls[1].opts, { width = 33, charset = "ascii", max_src_lines = 200 })

  cfg().setup({ mermaid = { max_src_lines = 7 } })
  r(FENCE)
  eq(calls[2].opts, { width = 40, charset = "unicode", max_src_lines = 7 })
end

T["diagrama"]["dentro de quote e de lista o crate recebe a largura que sobrou"] = function()
  local quoted = r("> " .. FENCE:gsub("\n", "\n> "), { width = 40 })
  eq(calls[1].opts.width, 38)
  eq(quoted.lines[1], "│ ┌─┐")
  -- A marca acompanha o prefixo: cobre o desenho, não a borda do quote.
  local covered = {}
  for _, mark in ipairs(quoted.marks) do
    if mark.hl == "DeckleMermaid" then
      covered[#covered + 1] = quoted.lines[mark.row + 1]:sub(mark.col + 1, mark.end_col)
    end
  end
  eq(covered, ART)

  -- Mesma largura e mesmo conteúdo seriam um hit: limpa para o crate ser chamado de novo.
  mermaid.cache_clear()
  local listed = r("- item\n\n  " .. FENCE:gsub("\n", "\n  "), { width = 40 })
  eq(calls[2].opts.width, 38)
  eq(listed.lines[3], "  ┌─┐")
end

T["diagrama"]["só `mermaid` minúsculo e exato é do módulo: o resto vai para o código"] = function()
  r("```Mermaid\nx\n```")
  r("```mermaidx\nx\n```")
  r("```\nx\n```")
  r("```lua\nx\n```")
  r("    x")
  r("```mermaid extra words\nx\n```")
  -- Só o último: `lang` é a primeira palavra da info string.
  eq(#calls, 1)
end

T["diagrama"]["linha mais larga que a janela fica inteira, sem corte nem reticências"] = function()
  local wide = string.rep("─", 90)
  fake.responder = function()
    return { "┌" .. wide .. "┐", "│ largo │" }
  end
  local result = r(FENCE, { width = 30 })
  eq(result.lines[1], "┌" .. wide .. "┐")
  eq(vim.fn.strdisplaywidth(result.lines[1]) > 30, true)
  eq(count_in(result.lines, "…"), 0)
end

T["diagrama"]["diagram_ty opcional do bloco vai ao crate; sem ele a chave não existe"] = function()
  local ctx = { width = 40, charset = "unicode", indent = 0, depth = 0 }
  mermaid.render({ kind = "code", lang = "mermaid", lines = { "a" } }, ctx)
  eq(calls[1].opts.diagram_ty, nil)
  mermaid.render({ kind = "code", lang = "mermaid", lines = { "a" }, diagram_ty = "sequence" }, ctx)
  eq(calls[2].opts.diagram_ty, "sequence")
  -- Tipo errado é ignorado, não repassado.
  mermaid.render({ kind = "code", lang = "mermaid", lines = { "b" }, diagram_ty = 5 }, ctx)
  eq(calls[3].opts.diagram_ty, nil)
end

-- ---------------------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------------------

T["cache"] = unit_set()

T["cache"]["o mesmo bloco, largura e charset: um render do crate e o resto é hit"] = function()
  eq(mermaid.cache_stats(), { hits = 0, misses = 0, size = 0, limit = 64 })
  local first = r(FENCE)
  local second = r(FENCE)
  local third = r(FENCE)
  eq(#calls, 1)
  eq(mermaid.cache_stats(), { hits = 2, misses = 1, size = 1, limit = 64 })
  eq(first.lines, second.lines)
  eq(first.lines, third.lines)
  eq(first.marks, third.marks)
end

T["cache"]["largura, charset, conteúdo, max_src_lines e diagram_ty entram na chave"] = function()
  r(FENCE)
  eq(mermaid.cache_stats().misses, 1)

  r(FENCE, { width = 41 })
  eq(mermaid.cache_stats().misses, 2)

  r(FENCE, { charset = "ascii" })
  eq(mermaid.cache_stats().misses, 3)

  r((FENCE:gsub("B", "C")))
  eq(mermaid.cache_stats().misses, 4)

  cfg().setup({ mermaid = { max_src_lines = 150 } })
  r(FENCE)
  eq(mermaid.cache_stats().misses, 5)

  local ctx = { width = 40, charset = "unicode", indent = 0, depth = 0 }
  mermaid.render({ kind = "code", lang = "mermaid", lines = { "a" }, diagram_ty = "sequence" }, ctx)
  mermaid.render({ kind = "code", lang = "mermaid", lines = { "a" } }, ctx)
  eq(mermaid.cache_stats().misses, 7)

  -- Nenhum desses repetiu a chave: nenhum hit.
  eq(mermaid.cache_stats().hits, 0)
  eq(#calls, 7)
end

T["cache"]["a mesma chave volta a dar hit depois de outras"] = function()
  r(FENCE)
  r(FENCE, { width = 50 })
  r(FENCE)
  r(FENCE, { width = 50 })
  eq(mermaid.cache_stats(), { hits = 2, misses = 2, size = 2, limit = 64 })
  eq(#calls, 2)
end

T["cache"]["LRU: com limite 2, o menos recente sai e o recém-usado fica"] = function()
  mermaid.cache_limit = 2
  local function block(name)
    return "```mermaid\n" .. name .. "\n```"
  end
  r(block("a"))
  r(block("b"))
  r(block("a")) -- hit: a passa a ser o mais recente
  r(block("c")) -- entra c, sai b
  eq(mermaid.cache_stats(), { hits = 1, misses = 3, size = 2, limit = 2 })

  r(block("a")) -- ainda está
  eq(mermaid.cache_stats().hits, 2)
  r(block("b")) -- foi descartado: miss
  eq(mermaid.cache_stats().misses, 4)
  eq(mermaid.cache_stats().size, 2)
end

T["cache"]["limite 0 não guarda nada e nada quebra"] = function()
  mermaid.cache_limit = 0
  r(FENCE)
  r(FENCE)
  eq(#calls, 2)
  eq(mermaid.cache_stats().size, 0)
  eq(mermaid.cache_stats().hits, 0)
end

T["cache"]["o erro do render também é guardado: diagrama inválido não volta ao crate"] = function()
  local text = "```mermaid\nINVALID\n```"
  local first = r(text)
  local second = r(text)
  eq(#calls, 1)
  eq(mermaid.cache_stats(), { hits = 1, misses = 1, size = 1, limit = 64 })
  -- E o resultado é o mesmo degradado nas duas vezes.
  eq(first.lines, second.lines)
  eq(count_in(second.lines, "mermaid: parse error: boom"), 1)
end

T["cache"]["quem recebe as linhas pode alterá-las sem sujar o cache"] = function()
  local ctx = { width = 40, charset = "unicode", indent = 0, depth = 0 }
  local block = { kind = "code", lang = "mermaid", lines = { "a" } }
  local first = mermaid.render(block, ctx)
  first[1] = "alterada"
  first[#first + 1] = "lixo"
  local second = mermaid.render(block, ctx)
  eq(second, { "┌─┐", "│ a │", "└─┘" })
  eq(#calls, 1)
end

T["cache"]["cache_clear zera entradas e contadores"] = function()
  r(FENCE)
  r(FENCE)
  mermaid.cache_clear()
  eq(mermaid.cache_stats(), { hits = 0, misses = 0, size = 0, limit = 64 })
  r(FENCE)
  eq(#calls, 2)
end

T["cache"]["fonte com NUL no meio não quebra o hash"] = function()
  local ctx = { width = 40, charset = "unicode", indent = 0, depth = 0 }
  local block = { kind = "code", lang = "mermaid", lines = { "a\0b" } }
  eq(#mermaid.render(block, ctx), 3)
  mermaid.render(block, ctx)
  eq(mermaid.cache_stats().hits, 1)
end

T["cache"]["bloco com mais linhas que max_src_lines não passa pelo cache, e o erro vem do crate"] = function()
  cfg().setup({ mermaid = { max_src_lines = 3 } })
  local text = "```mermaid\n1\n2\n3\n4\n5\n```"
  local result = r(text, { width = 100 })
  eq(count_in(result.lines, "mermaid: source too large: 5 lines"), 1)
  eq(#calls, 1)
  r(text)
  eq(#calls, 2)
  eq(mermaid.cache_stats(), { hits = 0, misses = 0, size = 0, limit = 64 })
  -- No limite exato, desenha.
  cfg().setup({ mermaid = { max_src_lines = 5 } })
  eq(r(text).lines[1], "┌─┐")
end

-- ---------------------------------------------------------------------------------------
-- Degradação: sem módulo (camada 0)
-- ---------------------------------------------------------------------------------------

T["sem módulo"] = unit_set()

T["sem módulo"]["native.path quebrado: o bloco vira código cru com nota, o resto renderiza"] = function()
  local text = "# Título\n\n" .. FENCE .. "\n\ndepois"
  -- Com o crate, o mesmo arquivo desenha.
  local before = r(text)
  eq(#calls, 1)
  eq(count_in(before.lines, "┌─┐"), 1)
  eq(count_in(before.lines, "mermaid:"), 0)
  eq(marks_of(before, "DeckleMermaid"), 3)

  setup_native({ path = "/nonexistent/deckle_native.so" })
  native.reset()
  calls = {}
  local after = r(text, { width = 100 })

  eq(#calls, 0)
  eq(count_in(after.lines, "flowchart TD"), 1)
  eq(count_in(after.lines, "  A --> B"), 1)
  eq(count_in(after.lines, "mermaid: native module unavailable"), 1)
  eq(marks_of(after, "DeckleMermaid"), 0)
  -- O texto em volta é o mesmo.
  eq(after.lines[1], "Título")
  eq(after.lines[1], before.lines[1])
  eq(after.lines[#after.lines], "depois")
  eq(mermaid.last_error:find("/nonexistent/deckle_native.so", 1, true) ~= nil, true)
end

T["sem módulo"]["native.enabled = false: o mesmo, e o crate nem é chamado"] = function()
  local text = "# Título\n\n" .. FENCE .. "\n\ndepois"
  local before = r(text)

  setup_native({ enabled = false })
  calls = {}
  local after = r(text, { width = 100 })

  eq(#calls, 0)
  eq(count_in(after.lines, "flowchart TD"), 1)
  eq(count_in(after.lines, "mermaid: native.enabled is false"), 1)
  eq(after.lines[1], before.lines[1])
  eq(after.lines[#after.lines], "depois")
end

T["sem módulo"]["religar native.enabled traz o desenho de volta sem reiniciar"] = function()
  setup_native({ enabled = false })
  eq(count_in(r(FENCE).lines, "flowchart TD"), 1)
  setup_native({ enabled = true })
  eq(r(FENCE).lines, ART)
end

T["sem módulo"]["nativo indisponível não entra no cache e não conta hit nem miss"] = function()
  setup_native({ path = "/nonexistent/deckle_native.so" })
  native.reset()
  r(FENCE)
  r(FENCE)
  eq(mermaid.cache_stats(), { hits = 0, misses = 0, size = 0, limit = 64 })

  -- O módulo aparece (config corrigida, nova sessão simulada por reset): desenha na hora, sem
  -- ter guardado o "indisponível".
  cfg().setup({})
  native.reset()
  eq(r(FENCE).lines, ART)
  eq(mermaid.cache_stats().misses, 1)
end

T["sem módulo"]["um bloco que degrada não tira o desenho dos outros"] = function()
  local text = FENCE .. "\n\ntexto\n\n```mermaid\nINVALID\n```\n\n" .. FENCE:gsub("A", "Z")
  local result = r(text)
  eq(result.lines[1], "┌─┐")
  eq(count_in(result.lines, "texto"), 1)
  eq(count_in(result.lines, "INVALID"), 1)
  eq(count_in(result.lines, "mermaid: parse error: boom"), 1)
  -- Os dois válidos desenhados, o inválido não.
  eq(marks_of(result, "DeckleMermaid"), 6)
end

-- ---------------------------------------------------------------------------------------
-- Degradação: erro do crate e respostas ruins
-- ---------------------------------------------------------------------------------------

T["erro do crate"] = unit_set()

T["erro do crate"]["parse error: código cru e a nota sem o `mermaid ` repetido"] = function()
  local result = r("```mermaid\nINVALID\n```")
  eq(count_in(result.lines, "INVALID"), 1)
  eq(count_in(result.lines, "mermaid: parse error: boom"), 1)
  eq(mermaid.last_error, "mermaid parse error: boom")
  eq(marks_of(result, "DeckleMermaid"), 0)
end

T["erro do crate"]["fonte vazia: o bloco não desenha nada, como qualquer cerca vazia"] = function()
  local result = r("```mermaid\n```")
  eq(result.lines, {})
  eq(result.map, {})
  eq(mermaid.last_error, "empty mermaid source")
  -- E o resto do documento não nota.
  eq(r("antes\n\n```mermaid\n```\n\ndepois").lines, { "antes", "", "depois" })
end

T["erro do crate"]["resposta que não é lista de linhas vira degradação, não erro"] = function()
  for _, bad in ipairs({ {}, "texto", 5, true, { 1, 2 } }) do
    mermaid.cache_clear()
    fake.responder = function()
      return bad
    end
    local result = r("```mermaid\nflowchart TD\n```", { width = 100 })
    eq(count_in(result.lines, "flowchart TD"), 1)
    eq(count_in(result.lines, "mermaid: the native renderer returned no lines"), 1)
  end
end

T["erro do crate"]["erro que não é string não derruba o render"] = function()
  fake.responder = function()
    -- Um erro com valor de tabela, que o crate real não levanta mas o `pcall` pode receber.
    error(vim.deepcopy({ code = 7 }))
  end
  local result = r("```mermaid\nflowchart TD\n```")
  eq(count_in(result.lines, "flowchart TD"), 1)
  eq(count_in(result.lines, "mermaid:"), 1)
end

T["erro do crate"]["erro de Lua dentro do crate (wrapper) também degrada"] = function()
  fake.responder = function()
    error("attempt to call a nil value")
  end
  local result = r("```mermaid\nflowchart TD\n```")
  eq(count_in(result.lines, "flowchart TD"), 1)
  eq(count_in(result.lines, "mermaid:"), 1)
end

T["erro do crate"]["quebra de linha na mensagem não quebra a nota"] = function()
  fake.responder = function()
    error("mermaid parse error: linha um\n\tlinha dois", 0)
  end
  local result = r("```mermaid\nx\n```", { width = 80 })
  eq(count_in(result.lines, "mermaid: parse error: linha um linha dois"), 1)
  for _, line in ipairs(result.lines) do
    eq(line:find("\n", 1, true), nil)
  end
end

-- ---------------------------------------------------------------------------------------
-- A nota
-- ---------------------------------------------------------------------------------------

T["nota"] = unit_set()

T["nota"]["cabe na largura: cortada com reticências em Unicode e três pontos em ASCII"] = function()
  fake.responder = function()
    error("mermaid parse error: " .. string.rep("palavra ", 20), 0)
  end
  local function note_of(result)
    for _, line in ipairs(result.lines) do
      if line:find("mermaid: ", 1, true) then
        return line
      end
    end
  end

  local unicode = note_of(r("```mermaid\nx\n```", { width = 40 }))
  eq(vim.fn.strdisplaywidth(unicode) <= 40, true)
  eq(unicode:sub(-3), "…")
  eq(vim.startswith(unicode, "mermaid: parse error: "), true)

  mermaid.cache_clear()
  local ascii = note_of(r("```mermaid\nx\n```", { width = 40, charset = "ascii" }))
  eq(vim.fn.strdisplaywidth(ascii) <= 40, true)
  eq(ascii:sub(-3), "...")
  eq(ascii:find("[\128-\255]"), nil)
end

T["nota"]["mensagem com CJK e emoji é medida em células e não é partida ao meio"] = function()
  local function note_of(result)
    for _, line in ipairs(result.lines) do
      if line:find("mermaid: ", 1, true) then
        return line
      end
    end
  end

  -- O prefixo tem 9 células. Com 20, sobram 11, e a reticência ocupa uma: cabem 5 ideogramas
  -- de duas células (10), e o sexto estouraria. Contar bytes ou codepoints partiria um deles.
  fake.responder = function()
    error("mermaid 日本語日本語日本語日本語日本語", 0)
  end
  local cjk = note_of(r("```mermaid\nx\n```", { width = 20 }))
  eq(cjk, "mermaid: 日本語日本…")
  eq(vim.fn.strdisplaywidth(cjk), 20)

  mermaid.cache_clear()
  fake.responder = function()
    error("mermaid 😀😀😀😀😀😀😀😀", 0)
  end
  local emoji = note_of(r("```mermaid\nx\n```", { width = 20 }))
  eq(emoji, "mermaid: 😀😀😀😀😀…")
  eq(vim.fn.strdisplaywidth(emoji), 20)
end

T["nota"]["mensagem curta cabe inteira, sem reticências"] = function()
  local result = r("```mermaid\nINVALID\n```", { width = 80 })
  eq(count_in(result.lines, "mermaid: parse error: boom"), 1)
  eq(count_in(result.lines, "…"), 0)
end

T["nota"]["o bloco degradado é o do code.lua: moldura com rótulo mermaid e a nota sob ela, uma vez"] = function()
  local result = r("```mermaid\nINVALID\n```", { width = 80 })
  -- Moldura de três linhas (borda, código, borda) e a nota por último.
  eq(#result.lines, 4)
  eq(vim.startswith(result.lines[1], "╭─ mermaid "), true)
  eq(result.lines[2]:find("INVALID", 1, true) ~= nil, true)
  eq(vim.startswith(result.lines[3], "╰"), true)
  eq(result.lines[4], "mermaid: parse error: boom")
  eq(count_in(result.lines, "mermaid: parse error: boom"), 1)
  -- A nota é a do code.lua (`DeckleCodeNote`), e não há marca de diagrama.
  local notes = {}
  for _, mark in ipairs(result.marks) do
    if mark.hl == "DeckleCodeNote" then
      notes[#notes + 1] = mark
    end
  end
  eq(notes, { { row = 3, col = 0, end_col = #result.lines[4], hl = "DeckleCodeNote" } })
  eq(marks_of(result, "DeckleMermaid"), 0)
end

T["nota"]["em ASCII a moldura e a nota não têm byte fora do ASCII"] = function()
  local result = r("```mermaid\nINVALID\n```", { width = 80, charset = "ascii" })
  eq(table.concat(result.lines, "\n"):find("[\128-\255]"), nil)
  eq(result.lines[#result.lines], "mermaid: parse error: boom")
end

T["nota"]["o bloco cru sai de render/code.lua pelo contrato: kind, lang, lines, note, src_*"] = function()
  local seen
  with_module("deckle.render.code", {
    render = function(block, ctx)
      seen = { block = block, ctx_width = ctx.width, ctx_charset = ctx.charset }
      return { "x" }, {}
    end,
  }, function()
    r("\n\n```mermaid\nINVALID\n  linha dois\n```", { width = 50 })
  end)
  eq(seen.block, {
    kind = "code",
    lang = "mermaid",
    lines = { "INVALID", "  linha dois" },
    note = "mermaid: parse error: boom",
    src_start = 2,
    src_end = 6,
  })
  eq(seen.ctx_width, 50)
  eq(seen.ctx_charset, "unicode")
end

T["nota"]["o render de código lançando erro cai no aviso do dispatcher, só para esse bloco"] = function()
  with_module("deckle.render.code", {
    render = function()
      error("code is broken")
    end,
  }, function()
    local result = r("antes\n\n```mermaid\nINVALID\n```\n\ndepois")
    eq(result.lines, { "antes", "", "[deckle: could not render code block]", "", "depois" })
  end)
end

-- ---------------------------------------------------------------------------------------
-- Layout simplificado: o crate desenha e avisa (`lines, notice`)
-- ---------------------------------------------------------------------------------------

T["layout simplificado"] = unit_set()

local SIMPLIFIED =
  "layout simplified: subgraph boxes removed, the text layout cannot route edges across them"

T["layout simplificado"]["o desenho sai, com o aviso sob ele e sem o prefixo mermaid:"] = function()
  fake.responder = function()
    return { "┌─┐", "│ x │", "└─┘" }, SIMPLIFIED
  end
  local result = r("antes\n\n" .. FENCE .. "\n\ndepois", { width = 100 })
  eq(result.lines, { "antes", "", "┌─┐", "│ x │", "└─┘", SIMPLIFIED, "", "depois" })
  -- O desenho tem a cor dele, e o aviso a da nota. Não é degradação: nenhum bloco de código.
  eq(marks_of(result, "DeckleMermaid"), 3)
  local notes = {}
  for _, mark in ipairs(result.marks) do
    if mark.hl == "DeckleCodeNote" then
      notes[#notes + 1] = mark
    end
  end
  eq(notes, { { row = 5, col = 0, end_col = #SIMPLIFIED, hl = "DeckleCodeNote" } })
  eq(count_in(result.lines, "mermaid: "), 0)
  eq(count_in(result.lines, "╭"), 0)
  eq(mermaid.last_notice, SIMPLIFIED)
  eq(mermaid.last_error, nil)
end

T["layout simplificado"]["o mapa de sync cobre o desenho e o aviso"] = function()
  fake.responder = function()
    return { "┌─┐", "│ x │", "└─┘" }, SIMPLIFIED
  end
  local result = r(FENCE, { width = 100 })
  eq(result.map, { { preview_start = 0, preview_end = 4, src_start = 0, src_end = 4 } })
end

T["layout simplificado"]["o aviso é cortado na largura: reticências em Unicode, três pontos em ASCII"] = function()
  fake.responder = function()
    return { "┌─┐", "│ x │", "└─┘" }, SIMPLIFIED
  end
  local unicode = r(FENCE, { width = 40 }).lines
  eq(vim.fn.strdisplaywidth(unicode[#unicode]) <= 40, true)
  eq(unicode[#unicode]:sub(-3), "…")
  eq(vim.startswith(unicode[#unicode], "layout simplified: subgraph"), true)
  -- O completo não se perde: fica em `last_notice`.
  eq(mermaid.last_notice, SIMPLIFIED)

  mermaid.cache_clear()
  local ascii = r(FENCE, { width = 40, charset = "ascii" }).lines
  eq(vim.fn.strdisplaywidth(ascii[#ascii]) <= 40, true)
  eq(ascii[#ascii]:sub(-3), "...")
  eq(ascii[#ascii]:find("[\128-\255]"), nil)
end

T["layout simplificado"]["o cache guarda o aviso: o segundo render não volta ao crate"] = function()
  fake.responder = function()
    return { "┌─┐", "│ x │", "└─┘" }, SIMPLIFIED
  end
  local first = r(FENCE, { width = 100 })
  mermaid.last_notice = nil
  local second = r(FENCE, { width = 100 })
  eq(#calls, 1)
  eq(second.lines, first.lines)
  eq(second.marks, first.marks)
  eq(mermaid.last_notice, SIMPLIFIED)
  eq(mermaid.cache_stats().hits, 1)
end

T["layout simplificado"]["desenho sem aviso não ganha linha nenhuma e zera o último aviso"] = function()
  fake.responder = function(src)
    if src:find("SIMPLE", 1, true) then
      return { "┌─┐", "│ x │", "└─┘" }, SIMPLIFIED
    end
    return { "┌─┐", "│ y │", "└─┘" }
  end
  r("```mermaid\nSIMPLE\n```", { width = 100 })
  eq(mermaid.last_notice, SIMPLIFIED)
  local plain = r("```mermaid\nplain\n```", { width = 100 })
  eq(plain.lines, { "┌─┐", "│ y │", "└─┘" })
  eq(mermaid.last_notice, nil)
end

T["layout simplificado"]["aviso que não é texto (ou é vazio) é ignorado, o desenho sai igual"] = function()
  for _, notice in ipairs({ 42, "", true }) do
    mermaid.cache_clear()
    fake.responder = function()
      return { "┌─┐", "│ x │", "└─┘" }, notice
    end
    eq(r(FENCE, { width = 100 }).lines, { "┌─┐", "│ x │", "└─┘" })
  end
end

-- ---------------------------------------------------------------------------------------
-- Integração: o preview inteiro, num Neovim filho (gates 2, 3 e 4)
-- ---------------------------------------------------------------------------------------

local child = MiniTest.new_child_neovim()

local I = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.columns = 120
      child.o.lines = 40
      child.lua([==[
        -- `charset = "auto"` vira ASCII com TERM=linux/dumb, que é o que uma CI pode ter.
        vim.env.TERM = "xterm-256color"

        -- Crate falso, na forma do real: erro é `error(msg, 0)`, e `_G.calls` conta as idas.
        _G.calls = 0
        _G.install_stub = function()
          package.loaded.deckle_native = {
            render = function(src, opts)
              _G.calls = _G.calls + 1
              if src:find("INVALID", 1, true) then
                error("mermaid parse error: boom", 0)
              end
              local out = { ("ART<%s,%d>"):format(opts.charset, opts.width) }
              for line in src:gmatch("[^\n]+") do
                out[#out + 1] = "~ " .. line
              end
              return out
            end,
            supported_types = function() return { "flowchart" } end,
            version = function() return "0.0.0-stub" end,
          }
          require("deckle.native").reset()
        end

        _G.use_source = function(lines)
          vim.cmd("enew")
          vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
          vim.bo.filetype = "markdown"
          _G.src = vim.api.nvim_get_current_buf()
        end

        _G.preview_text = function()
          local st = require("deckle.preview").state(_G.src)
          return vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
        end

        _G.wait_for = function(cond)
          return vim.wait(2000, cond, 10)
        end
      ]==])
    end,
    post_once = child.stop,
  },
})

local DOC = {
  "# Título",
  "",
  "antes",
  "",
  "```mermaid",
  "sequenceDiagram",
  "  Alice->>Bob: Hello",
  "```",
  "",
  "meio",
  "",
  "```mermaid",
  "graph TD",
  "  INVALID",
  "```",
  "",
  "depois",
}

---@param lines string[]
local function open_preview(lines)
  child.lua("_G.use_source(...)", { lines })
  child.cmd("Deckle open")
end

---@return string[]
local function preview_lines()
  return child.lua_get("_G.preview_text()")
end

---@param lines string[]
---@param text string
---@return boolean
local function has(lines, text)
  return count_in(lines, text) > 0
end

I["gate 1 (com o crate): o sequenceDiagram vira desenho e o resto do documento renderiza"] = function()
  child.lua("_G.install_stub()")
  open_preview(DOC)
  local lines = preview_lines()
  eq(has(lines, "ART<unicode,"), true)
  eq(has(lines, "~ sequenceDiagram"), true)
  eq(lines[1], "Título")
  eq(has(lines, "antes"), true)
  eq(has(lines, "meio"), true)
  eq(has(lines, "depois"), true)
end

I["gate 2: com o .so ausente (native.path quebrado) o mesmo arquivo abre e o bloco vira código cru"] = function()
  child.lua([[
    _G.install_stub()
    require("deckle").setup({ native = { path = "/nonexistent/deckle_native.so" } })
    require("deckle.native").reset()
  ]])
  open_preview(DOC)

  local lines = preview_lines()
  -- Código cru dos dois blocos, com a nota, e nenhum desenho.
  eq(has(lines, "sequenceDiagram"), true)
  eq(has(lines, "Alice->>Bob: Hello"), true)
  eq(has(lines, "ART<"), false)
  eq(count_in(lines, "mermaid: native module unavailable"), 2)
  -- O resto do documento está lá.
  eq(lines[1], "Título")
  eq(has(lines, "antes"), true)
  eq(has(lines, "meio"), true)
  eq(lines[#lines], "depois")
  eq(child.lua_get("_G.calls"), 0)
  eq(child.lua_get([[require("deckle.preview").state(_G.src).renders]]), 1)
end

I["gate 2: com native.enabled = false, idem"] = function()
  child.lua([[
    _G.install_stub()
    require("deckle").setup({ native = { enabled = false } })
  ]])
  open_preview(DOC)
  local lines = preview_lines()
  eq(has(lines, "Alice->>Bob: Hello"), true)
  eq(has(lines, "ART<"), false)
  eq(count_in(lines, "mermaid: native.enabled is false"), 2)
  eq(lines[#lines], "depois")
  eq(child.lua_get("_G.calls"), 0)
end

I["gate 2: o fonte não ganha nada com a degradação (ADR-0003)"] = function()
  child.lua([[
    require("deckle").setup({ native = { path = "/nonexistent/deckle_native.so" } })
  ]])
  open_preview(DOC)
  local src_lines = child.lua_get("vim.api.nvim_buf_get_lines(_G.src, 0, -1, false)")
  eq(src_lines, DOC)
  -- Só os namespaces do deckle: o Neovim põe os dele no fonte (o nightly liga o treesitter no
  -- filetype markdown), e isso não é da conta do plugin.
  eq(
    child.lua_get([[(function()
      local n = 0
      for name, id in pairs(vim.api.nvim_get_namespaces()) do
        if name:find("^deckle") then
          n = n + #vim.api.nvim_buf_get_extmarks(_G.src, id, 0, -1, {})
        end
      end
      return n
    end)()]]),
    0
  )
  eq(child.lua_get("vim.bo[_G.src].modifiable"), true)
end

I["gate 3: diagrama inválido degrada só aquele bloco, o outro e o texto continuam"] = function()
  child.lua("_G.install_stub()")
  open_preview(DOC)
  local lines = preview_lines()
  -- O válido está desenhado.
  eq(has(lines, "~ sequenceDiagram"), true)
  -- O inválido virou código cru com a nota.
  eq(has(lines, "  INVALID"), true)
  eq(count_in(lines, "mermaid: parse error: boom"), 1)
  eq(has(lines, "~ graph TD"), false)
  -- E o texto em volta está inteiro.
  eq(lines[1], "Título")
  eq(has(lines, "antes"), true)
  eq(has(lines, "meio"), true)
  eq(lines[#lines], "depois")
  eq(child.lua_get([[require("deckle.preview").state(_G.src).renders]]), 1)
end

I["gate 4: fechar e reabrir o mesmo documento acerta o cache, medido pelo contador"] = function()
  child.lua("_G.install_stub()")
  open_preview(DOC)
  local first = child.lua_get([[require("deckle.render.mermaid").cache_stats()]])
  -- Dois blocos, os dois foram ao crate pela primeira vez.
  eq(first.misses, 2)
  eq(first.hits, 0)
  eq(child.lua_get("_G.calls"), 2)

  child.cmd("Deckle close")
  child.cmd("Deckle open")
  local second = child.lua_get([[require("deckle.render.mermaid").cache_stats()]])
  eq(second.misses, 2)
  eq(second.hits, 2)
  -- O crate não foi chamado de novo, nem para o diagrama inválido.
  eq(child.lua_get("_G.calls"), 2)
  eq(has(preview_lines(), "~ sequenceDiagram"), true)
end

I["editar o texto em volta re-renderiza sem voltar ao crate"] = function()
  child.lua("_G.install_stub()")
  open_preview(DOC)
  eq(child.lua_get("_G.calls"), 2)

  child.lua([[
    vim.api.nvim_buf_set_lines(_G.src, 2, 3, false, { "antes, editado" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = _G.src })
  ]])
  eq(
    child.lua_get(
      [[_G.wait_for(function() return require("deckle.preview").state(_G.src).renders >= 2 end)]]
    ),
    true
  )
  eq(has(preview_lines(), "antes, editado"), true)
  eq(child.lua_get("_G.calls"), 2)
  eq(child.lua_get([[require("deckle.render.mermaid").cache_stats().hits]]), 2)
end

I["mudar a largura da janela é outra chave: vai ao crate de novo, e o desenho acompanha"] = function()
  child.lua("_G.install_stub()")
  open_preview({ "```mermaid", "graph TD", "```" })
  local before = preview_lines()[1]
  eq(vim.startswith(before, "ART<unicode,"), true)
  eq(child.lua_get("_G.calls"), 1)

  child.lua([[
    local st = require("deckle.preview").state(_G.src)
    vim.api.nvim_win_set_width(st.win, 30)
    vim.api.nvim_exec_autocmds("WinResized", {})
  ]])
  eq(
    child.lua_get(
      [[_G.wait_for(function() return require("deckle.preview").state(_G.src).renders >= 2 end)]]
    ),
    true
  )
  eq(preview_lines()[1], "ART<unicode,30>")
  eq(child.lua_get("_G.calls"), 2)
end

T["integração"] = I

return T
