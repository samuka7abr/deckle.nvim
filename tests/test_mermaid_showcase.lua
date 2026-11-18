-- `examples/mermaid.md`: o showcase só de Mermaid também é teste.
--
-- Aqui vale o que não depende do `.so`: o arquivo tem um diagrama grande de cada um dos 14 tipos
-- que o renderer de texto cobre, os dois diagramas do README do ILZA estão copiados sem
-- alteração dos fixtures do crate, o `showcase.md` aponta para ele, e o render do arquivo inteiro
-- não dá erro, desenhe ele o Mermaid ou degrade para código (camada 0). O que prova que cada
-- diagrama é **desenhado** (e que só o `pie` degrada) é `cargo test` (as mesmas fontes, no crate)
-- e `tests/native/test_mermaid_showcase_native.lua` (o preview de verdade, com o `.so`).
--
-- O render roda num Neovim filho, como em `tests/test_showcase.lua`: o Mermaid carrega o `.so`
-- quando ele existe, e esse estado não pode vazar para os outros arquivos.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h")
local H = dofile(tests_dir .. "/doc_helpers.lua")

local MERMAID_PATH = H.repo_root .. "/examples/mermaid.md"
local FIXTURES = "crates/deckle-native/tests/fixtures"

--- Os 14 tipos de `deckle_native.supported_types()`, pelo nome que o merman dá (ADR-0002).
local TYPES = {
  "class",
  "er",
  "flowchart",
  "gantt",
  "gitgraph",
  "journey",
  "kanban",
  "mindmap",
  "packet",
  "sequence",
  "state",
  "timeline",
  "treeView",
  "xychart",
}

--- Palavra-chave de abertura do Mermaid, para o nome da família no merman.
local FAMILY = {
  flowchart = "flowchart",
  graph = "flowchart",
  sequenceDiagram = "sequence",
  classDiagram = "class",
  stateDiagram = "state",
  ["stateDiagram-v2"] = "state",
  erDiagram = "er",
  gantt = "gantt",
  gitGraph = "gitgraph",
  journey = "journey",
  kanban = "kanban",
  mindmap = "mindmap",
  ["packet-beta"] = "packet",
  packet = "packet",
  timeline = "timeline",
  ["treeView-beta"] = "treeView",
  treeView = "treeView",
  ["xychart-beta"] = "xychart",
  xychart = "xychart",
  pie = "pie",
}

---@return deckle.test.Fence[] só os blocos `mermaid`, na ordem
local function mermaid_blocks()
  local out = {}
  for _, fence in ipairs(H.fences(vim.fn.readfile(MERMAID_PATH))) do
    if fence.lang == "mermaid" then
      out[#out + 1] = fence
    end
  end
  return out
end

---@param fence deckle.test.Fence
---@return string
local function family_of(fence)
  local keyword = (fence.lines[1] or ""):match("^%S+") or ""
  return FAMILY[keyword] or keyword
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
          -- Um binário que `:Deckle install` pôs no diretório de dados de quem roda a suíte (de
          -- outra versão do plugin) não pode entrar: o teste vale para o `.so` do repositório.
          vim.env.XDG_DATA_HOME = vim.fn.tempname()
          _G.path = ...

          _G.render = function(width, charset)
            local ir = require("deckle.parse").parse_lines(vim.fn.readfile(_G.path))
            local result = require("deckle.render").render(ir, { width = width, charset = charset })
            local errors, notes, mermaid = 0, 0, 0
            for _, mark in ipairs(result.marks) do
              if mark.hl == "DeckleError" then
                errors = errors + 1
              elseif mark.hl == "DeckleCodeNote" then
                notes = notes + 1
              elseif mark.hl == "DeckleMermaid" then
                mermaid = mermaid + 1
              end
            end
            return {
              lines = #result.lines,
              blocks = #ir,
              mapped = #result.map,
              errors = errors,
              notes = notes,
              mermaid = mermaid,
              text = result.lines,
            }
          end
        ]==],
        { MERMAID_PATH }
      )
    end,
    post_once = child.stop,
  },
})

T["estrutura"] = new_set()

T["estrutura"]["tem um diagrama grande de cada um dos 14 tipos, e um pie no fim"] = function()
  local by_family = {}
  for _, fence in ipairs(mermaid_blocks()) do
    local family = family_of(fence)
    by_family[family] = by_family[family] or {}
    table.insert(by_family[family], fence)
  end

  for _, ty in ipairs(TYPES) do
    eq({ ty, by_family[ty] ~= nil }, { ty, true })
  end
  -- "Grande": cada tipo tem pelo menos um bloco com mais de 10 linhas, salvo os que são curtos
  -- por natureza (packet, o gráfico de barras horizontal).
  local short = { packet = true, xychart = true }
  for _, ty in ipairs(TYPES) do
    local longest = 0
    for _, fence in ipairs(by_family[ty]) do
      longest = math.max(longest, #fence.lines)
    end
    eq({ ty, longest > (short[ty] and 4 or 10) }, { ty, true })
  end

  -- Flowchart: TB, LR, RL, BT, o de 50+ nós, a sintaxe `@{ shape }` e os dois do ILZA.
  eq(#by_family.flowchart >= 7, true)
  local directions = {}
  for _, fence in ipairs(by_family.flowchart) do
    directions[fence.lines[1]:match("^%S+%s+(%a+)")] = true
  end
  for _, dir in ipairs({ "TB", "LR", "RL", "BT" }) do
    eq({ dir, directions[dir] }, { dir, true })
  end
  local biggest = 0
  for _, fence in ipairs(by_family.flowchart) do
    local n = 0
    for _, line in ipairs(fence.lines) do
      if line:find(":::", 1, true) then
        n = n + 1
      end
    end
    biggest = math.max(biggest, n)
  end
  eq(biggest >= 50, true)

  -- E exatamente um `pie`, que o renderer de texto não cobre.
  eq(#(by_family.pie or {}), 1)
  eq(mermaid_blocks()[#mermaid_blocks()].lines[1]:match("^pie") ~= nil, true)
end

T["estrutura"]["os diagramas do ILZA são o README copiado sem alteração"] = function()
  local blocks = {}
  for _, fence in ipairs(mermaid_blocks()) do
    if fence.heading == "README do ILZA" then
      blocks[#blocks + 1] = fence.lines
    end
  end
  eq(#blocks, 2)
  eq(blocks[1], H.read(FIXTURES .. "/ilza_architecture.mmd"))
  eq(blocks[2], H.read(FIXTURES .. "/ilza_modules.mmd"))
end

T["estrutura"]["o showcase geral aponta para o de Mermaid, e o arquivo existe"] = function()
  local links = {}
  for _, line in ipairs(H.without_fences(H.read("examples/showcase.md"))) do
    for target in line:gmatch("%]%(([^)]+)%)") do
      links[#links + 1] = target
    end
  end
  eq(vim.tbl_contains(links, "mermaid.md"), true)
  eq(vim.uv.fs_stat(MERMAID_PATH) ~= nil, true)
end

T["estrutura"]["o texto do arquivo não promete cor: estilo e cor estão lá só para não quebrar"] = function()
  local text = table.concat(vim.fn.readfile(MERMAID_PATH), "\n")
  for _, needle in ipairs({ "classDef", "linkStyle", "rect rgb(", "box rgb(", "style " }) do
    eq({ needle, text:find(needle, 1, true) ~= nil }, { needle, true })
  end
end

T["render"] = new_set()

T["render"]["o arquivo inteiro renderiza sem erro em várias larguras e nos dois charsets"] = function()
  local native = child.lua_get([[require("deckle.native").get() ~= nil]])
  local blocks = #mermaid_blocks()
  for _, charset in ipairs({ "unicode", "ascii" }) do
    for _, width in ipairs({ 20, 60, 100, 200 }) do
      local r = child.lua_get("_G.render(...)", { width, charset })
      local where = ("largura %d, %s"):format(width, charset)
      eq({ where, r.errors }, { where, 0 })
      eq({ where, r.lines > 300 }, { where, true })
      -- Todo bloco de topo que desenhou algo está no mapa de sync.
      eq({ where, r.mapped }, { where, r.blocks })
      if native then
        -- Com o `.so`, só o `pie` degrada (a nota `mermaid:`); os dois do ILZA levam o aviso de
        -- layout simplificado, que não tem esse prefixo.
        local degraded = 0
        for _, line in ipairs(r.text) do
          if vim.startswith(line, "mermaid: ") then
            degraded = degraded + 1
          end
        end
        eq({ where, degraded }, { where, 1 })
        eq({ where, r.mermaid > 0 }, { where, true })
      else
        -- Camada 0: cada bloco vira código com a nota do porquê.
        eq({ where, r.mermaid }, { where, 0 })
        eq({ where, r.notes }, { where, blocks })
      end
    end
  end
end

return T
