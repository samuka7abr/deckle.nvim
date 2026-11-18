-- O showcase de Mermaid (`examples/mermaid.md`) com o `.so` de verdade: nenhum bloco degrada,
-- salvo o `pie` da seção "Degradação esperada".
--
-- Como `tests/native/test_mermaid_native.lua`: sem `lua/deckle_native.so` os casos são **pulados
-- com aviso**, e `DECKLE_REQUIRE_NATIVE=1` (o job `native` da CI, por `scripts/test-native.sh`)
-- transforma o pulo em falha. O que vale sem o `.so` (a estrutura do arquivo, o render em
-- camada 0) está em `tests/test_mermaid_showcase.lua`, e o crate renderiza as mesmas fontes em
-- `cargo test`.
--
-- "Nenhum bloco degradou" tem duas metades, e as duas são conferidas: a nota `mermaid: ...` (a da
-- degradação) aparece uma vez, no `pie`; e a fonte de cada diagrama desenhado **não** aparece no
-- preview como código. Os dois diagramas do README do ILZA saem desenhados com o aviso de layout
-- simplificado (outro texto, sem o prefixo `mermaid:`); o teste fixa quais são.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h:h")
local H = dofile(tests_dir .. "/doc_helpers.lua")

local MERMAID_PATH = H.repo_root .. "/examples/mermaid.md"
local so_path = H.repo_root .. "/lua/deckle_native.so"
local has_so = vim.uv.fs_stat(so_path) ~= nil
local required = vim.env.DECKLE_REQUIRE_NATIVE == "1"

--- Orçamento de tempo do render do arquivo inteiro (todos os blocos), com folga: em release o crate
--- gasta algumas centenas de milissegundos no total, e a CI é lenta.
local BUDGET_MS = 5000

if not has_so and not required then
  io.stderr:write(
    "[deckle] tests/native/test_mermaid_showcase_native.lua: PULADO, lua/deckle_native.so nao"
      .. " existe (rode `make native`; scripts/test-native.sh faz isso)\n"
  )
end

--- Embrulha um caso: pula (ou falha, com `DECKLE_REQUIRE_NATIVE=1`) se não há `.so`.
---@param fn fun()
---@return fun()
local function native_case(fn)
  return function()
    if not has_so then
      if required then
        error(
          "DECKLE_REQUIRE_NATIVE=1, mas lua/deckle_native.so nao existe (make native falhou?)",
          0
        )
      end
      MiniTest.skip("lua/deckle_native.so nao existe (rode `make native`)")
    end
    fn()
  end
end

local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.columns = 120
      child.o.lines = 40
      child.lua(
        [==[
          -- `charset = "auto"` vira ASCII com TERM=linux/dumb, que é o que uma CI pode ter.
          vim.env.TERM = "xterm-256color"
          -- O binário que vale é o `lua/deckle_native.so` do repositório, e não um que
          -- `:Deckle install` pôs no diretório de dados de quem roda a suíte.
          vim.env.XDG_DATA_HOME = vim.fn.tempname()
          _G.path = ...

          _G.notes = {}
          vim.notify = function(msg, level)
            table.insert(_G.notes, { msg = msg, level = level })
          end

          _G.state = function()
            return require("deckle.preview").state(_G.src)
          end

          _G.stats = function()
            return require("deckle.render.mermaid").cache_stats()
          end

          --- Render do arquivo inteiro e o tempo gasto, em milissegundos.
          _G.timed_render = function(width, charset)
            local ir = require("deckle.parse").parse_lines(vim.fn.readfile(_G.path))
            local t0 = vim.uv.hrtime()
            local result = require("deckle.render").render(ir, { width = width, charset = charset })
            return { ms = (vim.uv.hrtime() - t0) / 1e6, lines = result.lines, marks = result.marks }
          end
        ]==],
        { MERMAID_PATH }
      )
    end,
    post_once = child.stop,
  },
})

---@return string[] a primeira linha de cada bloco mermaid do arquivo, na ordem
local function first_lines()
  local out = {}
  for _, fence in ipairs(H.fences(vim.fn.readfile(MERMAID_PATH))) do
    if fence.lang == "mermaid" then
      out[#out + 1] = fence.lines[1]
    end
  end
  return out
end

---@return string[] o fonte do `pie` (o único bloco que degrada)
local function pie_lines()
  for _, fence in ipairs(H.fences(vim.fn.readfile(MERMAID_PATH))) do
    if fence.lang == "mermaid" and vim.startswith(fence.lines[1], "pie") then
      return fence.lines
    end
  end
  return {}
end

---@param lines string[]
---@param prefix string
---@return string[] as linhas que começam com `prefix`
local function starting_with(lines, prefix)
  local out = {}
  for _, line in ipairs(lines) do
    if vim.startswith(line, prefix) then
      out[#out + 1] = line
    end
  end
  return out
end

T["nenhum bloco degrada, salvo o pie, e o preview de verdade abre sem aviso"] = native_case(
  function()
    child.lua([[
      vim.cmd("edit " .. vim.fn.fnameescape(_G.path))
      _G.src = vim.api.nvim_get_current_buf()
    ]])
    child.cmd("Deckle open")
    eq(child.lua_get([[vim.wait(5000, function() return _G.state().renders >= 1 end, 10)]]), true)
    eq(child.lua_get("_G.notes"), {})

    local lines = child.lua_get([[vim.api.nvim_buf_get_lines(_G.state().buf, 0, -1, false)]])
    eq(#lines > 1000, true)

    -- Metade 1: a nota da degradação (`mermaid: ...`) aparece uma vez, e é a do `pie`.
    local degraded = starting_with(lines, "mermaid: ")
    eq(#degraded, 1)
    eq(degraded[1]:find("unsupported diagram", 1, true) ~= nil, true)
    -- (A nota é cortada na largura da janela, então o nome do tipo não está nela: o fonte do
    -- `pie` está, como código, logo acima.)
    eq(#starting_with(lines, "│ pie title Cobertura do showcase"), 1)

    -- Metade 2: nenhum dos outros 23 blocos está no preview como código. A primeira linha de
    -- cada um (`flowchart TB`, `sequenceDiagram`...) só aparece, inteira, no código cru.
    local firsts = first_lines()
    eq(#firsts > 20, true)
    for _, first in ipairs(firsts) do
      if not vim.startswith(first, "pie") then
        -- Dentro da moldura do código (`│ flowchart TB   │`) ela só estaria se o bloco tivesse
        -- degradado. (Fora dela pode aparecer, como o título da seção: `## gantt`.)
        eq({ first, #starting_with(lines, "│ " .. first) }, { first, 0 })
      end
    end

    -- Nenhuma marca de erro, e a moldura de código (`DeckleCodeBorder`) existe só em volta do pie.
    local counts = child.lua_get([[(function()
      local n = { mermaid = 0, note = 0, error = 0, border_rows = {} }
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(
        _G.state().buf, require("deckle.preview").ns, 0, -1, { details = true })) do
        local hl = m[4].hl_group
        if hl == "DeckleMermaid" then
          n.mermaid = n.mermaid + 1
        elseif hl == "DeckleCodeNote" then
          n.note = n.note + 1
        elseif hl == "DeckleError" then
          n.error = n.error + 1
        elseif hl == "DeckleCodeBorder" then
          n.border_rows[tostring(m[2])] = true
        end
      end
      local rows = 0
      for _ in pairs(n.border_rows) do
        rows = rows + 1
      end
      n.border_rows = rows
      return n
    end)()]])
    eq(counts.error, 0)
    eq(counts.mermaid > 500, true)
    -- Três notas: a do `pie` e o aviso de layout simplificado dos dois diagramas do ILZA.
    eq(counts.note, 3)
    -- A moldura de código (`DeckleCodeBorder`) existe só em volta do pie: borda, as linhas dele,
    -- borda.
    eq(counts.border_rows, #pie_lines() + 2)

    child.cmd("Deckle close")
    eq(child.lua_get("_G.notes"), {})
  end
)

T["só os dois diagramas do ILZA saem com o aviso de layout simplificado"] = native_case(function()
  local r = child.lua_get("_G.timed_render(...)", { 100, "unicode" })
  local simplified = starting_with(r.lines, "layout simplified: ")
  eq(#simplified, 2)
  for _, line in ipairs(simplified) do
    eq(line:find("subgraph boxes removed", 1, true) ~= nil, true)
  end
  -- O aviso vem logo abaixo do desenho, e o desenho tem os nós de lá.
  local text = table.concat(r.lines, "\n")
  for _, label in ipairs({ "Frontend", "TriageEngine", "OpenAI API", "app.py", "Factory DI" }) do
    eq({ label, text:find(label, 1, true) ~= nil }, { label, true })
  end
end)

T["estilo e cor (classDef, style, linkStyle, rect rgb, box) não degradam nada"] = native_case(
  function()
    -- Os blocos que têm estilo: se algum deles degradasse, o primeiro teste já teria falhado.
    -- Aqui o contrário: o mesmo diagrama sem o estilo sai com o mesmo desenho.
    local out = child.lua_get([[(function()
      local mermaid = require("deckle.render.mermaid")
      local ctx = { width = 100, charset = "unicode", indent = 0, depth = 0 }
      local function draw(src)
        local lines = mermaid.render({ kind = "code", lang = "mermaid", lines = vim.split(src, "\n") }, ctx)
        return lines
      end
      return {
        styled = draw("flowchart LR\n classDef k fill:#f00,stroke:#00f\n A[Um]:::k --> B[Dois]\n style B fill:#0f0\n linkStyle 0 stroke:#f0f\n class A k"),
        plain = draw("flowchart LR\n A[Um] --> B[Dois]"),
        seq = draw("sequenceDiagram\n box rgb(1,2,3) Grupo\n participant A\n participant B\n end\n rect rgb(200,0,0)\n A->>B: oi\n end"),
      }
    end)()]])
    eq(out.styled, out.plain)
    eq(#out.styled > 3, true)
    eq(table.concat(out.seq, "\n"):find("oi", 1, true) ~= nil, true)
    eq(table.concat(out.seq, "\n"):find("mermaid: ", 1, true), nil)
  end
)

T["o arquivo inteiro cabe no orçamento de tempo, e a segunda passada vem do cache"] = native_case(
  function()
    local cold = child.lua_get("_G.timed_render(...)", { 100, "unicode" })
    local after_cold = child.lua_get("_G.stats()")
    -- Todo bloco tem menos de `max_src_lines` linhas: todos passam pelo cache, nenhum acertou
    -- ainda.
    local blocks = #first_lines()
    eq(after_cold.misses, blocks)
    eq(after_cold.hits, 0)
    eq(after_cold.size, blocks)
    eq(cold.ms < BUDGET_MS, true)

    local warm = child.lua_get("_G.timed_render(...)", { 100, "unicode" })
    local after_warm = child.lua_get("_G.stats()")
    eq(after_warm.misses, blocks)
    eq(after_warm.hits, blocks)
    -- Do cache sai o mesmo desenho, bem mais rápido (e abaixo do orçamento por folga).
    eq(warm.lines, cold.lines)
    eq(warm.ms < BUDGET_MS, true)
    eq(warm.ms < cold.ms, true)

    -- Outra largura é outra chave: refaz o desenho, e continua dentro do orçamento.
    local wide = child.lua_get("_G.timed_render(...)", { 160, "unicode" })
    eq(wide.ms < BUDGET_MS, true)
    eq(child.lua_get("_G.stats()").misses, 2 * blocks)
  end
)

T["o arquivo inteiro em charset ascii: nenhum bloco degrada e a moldura é ASCII"] = native_case(
  function()
    local r = child.lua_get("_G.timed_render(...)", { 100, "ascii" })
    eq(#starting_with(r.lines, "mermaid: "), 1)
    eq(#starting_with(r.lines, "layout simplified: "), 2)
    eq(r.ms < BUDGET_MS, true)
    -- Nenhum caractere de caixa Unicode sobra (o texto do autor tem acento, emoji e CJK).
    local text = table.concat(r.lines, "\n")
    for _, glyph in ipairs({
      "┌",
      "┐",
      "└",
      "┘",
      "│",
      "─",
      "├",
      "┤",
      "╭",
      "╮",
      "╰",
      "╯",
    }) do
      eq({ glyph, text:find(glyph, 1, true) }, { glyph, nil })
    end
  end
)

return T
