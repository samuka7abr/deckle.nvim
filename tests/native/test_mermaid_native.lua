-- O gate de saída da fase 7 com o `.so` de verdade: o merman desenha, o preview mostra.
--
-- Estes casos exigem `lua/deckle_native.so` (`make native`). Sem ele são **pulados com aviso**,
-- não falhos: o job `test` da CI não tem Rust e roda esta suíte inteira, e a prova de que a
-- degradação funciona sem o `.so` está em `tests/test_mermaid.lua`, que roda lá. O job `native`
-- roda este arquivo depois do `make native` (`scripts/test-native.sh`) com
-- `DECKLE_REQUIRE_NATIVE=1`, e aí a falta do `.so` **falha** em vez de pular: um job que existe
-- para provar o `.so` não pode passar sem ele.
--
-- Cada caso roda num Neovim filho, o que também isola o carregador (`deckle.native` guarda o
-- resultado da carga pela sessão inteira).

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local repo_root = vim.fn.fnamemodify(this_file, ":p:h:h:h")
local so_path = repo_root .. "/lua/deckle_native.so"

local has_so = vim.uv.fs_stat(so_path) ~= nil
local required = vim.env.DECKLE_REQUIRE_NATIVE == "1"

if not has_so and not required then
  io.stderr:write(
    "[deckle] tests/native/test_mermaid_native.lua: PULADO, lua/deckle_native.so nao existe"
      .. " (rode `make native`; scripts/test-native.sh faz isso)\n"
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
      child.lua([==[
        -- `charset = "auto"` vira ASCII com TERM=linux/dumb, que é o que uma CI pode ter.
        vim.env.TERM = "xterm-256color"

        _G.use_source = function(lines)
          vim.cmd("enew")
          vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
          vim.bo.filetype = "markdown"
          _G.src = vim.api.nvim_get_current_buf()
        end

        _G.state = function()
          return require("deckle.preview").state(_G.src)
        end

        _G.preview_text = function()
          return vim.api.nvim_buf_get_lines(_G.state().buf, 0, -1, false)
        end

        _G.stats = function()
          return require("deckle.render.mermaid").cache_stats()
        end
      ]==])
    end,
    post_once = child.stop,
  },
})

local SEQUENCE = {
  "```mermaid",
  "sequenceDiagram",
  "  Alice->>Bob: Hello Bob",
  "  Bob-->>Alice: Hi Alice",
  "```",
}

local FLOW = { "```mermaid", "flowchart TD", "  Start --> Stop", "```" }

---@param ... string[]
---@return string[] os blocos juntados, com uma linha em branco entre eles
local function doc(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    if #out > 0 then
      out[#out + 1] = ""
    end
    vim.list_extend(out, part)
  end
  return out
end

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
  for _, line in ipairs(lines) do
    if line:find(text, 1, true) then
      return true
    end
  end
  return false
end

---@return string[] grupos de highlight de todas as marcas do preview
local function preview_groups()
  return child.lua_get([[(function()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(
      _G.state().buf, require("deckle.preview").ns, 0, -1, { details = true })) do
      out[#out + 1] = m[4].hl_group
    end
    return out
  end)()]])
end

-- ---------------------------------------------------------------------------------------
-- Gate 1
-- ---------------------------------------------------------------------------------------

T["gate 1: com o .so, um sequenceDiagram renderiza no preview"] = native_case(function()
  open_preview(doc({ "# Título" }, SEQUENCE, { "depois" }))
  local lines = preview_lines()

  -- É desenho: os participantes e as mensagens estão lá, com borda, e a fonte do mermaid não.
  eq(has(lines, "Alice"), true)
  eq(has(lines, "Bob"), true)
  eq(has(lines, "Hello Bob"), true)
  eq(has(lines, "Hi Alice"), true)
  eq(has(lines, "┌"), true)
  eq(has(lines, "sequenceDiagram"), false)
  eq(has(lines, "->>"), false)
  eq(has(lines, "mermaid:"), false)

  -- O resto do documento continua lá.
  eq(lines[1], "Título")
  eq(lines[#lines], "depois")

  -- Tem a cor do diagrama, e o mapa cobre o bloco inteiro apontando para a cerca do fonte.
  local groups = preview_groups()
  eq(vim.tbl_contains(groups, "DeckleMermaid"), true)
  local map = child.lua_get("_G.state().map")
  eq(#map, 3)
  eq(map[2].src_start, 2)
  eq(map[2].src_end, 7)
  eq(map[2].preview_end - map[2].preview_start > 4, true)

  local status = child.lua_get([[require("deckle.native").status()]])
  eq(status.loaded, true)
  eq(status.source, "runtimepath")
  eq(vim.endswith(status.path, "deckle_native.so"), true)
  eq(type(status.version), "string")
end)

T["gate 1: o fonte fica intocado (ADR-0003)"] = native_case(function()
  local source = doc({ "# Título" }, SEQUENCE)
  open_preview(source)
  eq(child.lua_get("vim.api.nvim_buf_get_lines(_G.src, 0, -1, false)"), source)
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
end)

-- ---------------------------------------------------------------------------------------
-- Gate 3
-- ---------------------------------------------------------------------------------------

T["gate 3: diagrama inválido degrada só aquele bloco e o resto renderiza"] = native_case(
  function()
    local invalid = { "```mermaid", "flowchart TD", "  A -->", "```" }
    open_preview(doc({ "# Título" }, FLOW, { "meio" }, invalid, SEQUENCE, { "depois" }))
    local lines = preview_lines()

    -- O inválido: código com moldura e a nota do crate, nada de desenho.
    eq(has(lines, "  A -->"), true)
    eq(has(lines, "mermaid: parse error"), true)
    -- Os válidos: desenhados (uma nota só, a do inválido).
    eq(has(lines, "Start"), true)
    eq(has(lines, "Stop"), true)
    eq(has(lines, "Hello Bob"), true)
    eq(has(lines, "sequenceDiagram"), false)
    -- O texto em volta está inteiro.
    eq(lines[1], "Título")
    eq(has(lines, "meio"), true)
    eq(lines[#lines], "depois")
    eq(
      #child.lua_get(
        [[vim.tbl_filter(function(l) return l:find("mermaid:", 1, true) end, _G.preview_text())]]
      ),
      1
    )
  end
)

T["gate 3: tipo que o renderer de texto não cobre degrada com a nota 'unsupported'"] = native_case(
  function()
    open_preview(doc({ "```mermaid", "pie title Pets", '  "Dogs" : 386', "```" }, { "depois" }))
    local lines = preview_lines()
    eq(has(lines, '"Dogs" : 386'), true)
    eq(has(lines, "mermaid: unsupported diagram"), true)
    eq(lines[#lines], "depois")
  end
)

T["gate 3: diagrama maior que mermaid.max_src_lines degrada com a nota"] = native_case(function()
  child.lua([[require("deckle").setup({ mermaid = { max_src_lines = 3 } })]])
  open_preview(doc({ "```mermaid", "flowchart TD", "  A --> B", "  B --> C", "  C --> D", "```" }))
  local lines = preview_lines()
  eq(has(lines, "mermaid: source too large"), true)
  eq(has(lines, "  B --> C"), true)
end)

-- ---------------------------------------------------------------------------------------
-- Gate 4
-- ---------------------------------------------------------------------------------------

T["gate 4: reabrir o mesmo documento acerta o cache, medido pelo contador"] = native_case(function()
  open_preview(doc(FLOW, SEQUENCE))
  local first = child.lua_get("_G.stats()")
  eq(first.misses, 2)
  eq(first.hits, 0)
  eq(first.size, 2)
  local drawn = preview_lines()

  child.cmd("Deckle close")
  child.cmd("Deckle open")
  local second = child.lua_get("_G.stats()")
  eq(second.misses, 2)
  eq(second.hits, 2)
  -- Do cache sai o mesmo desenho.
  eq(preview_lines(), drawn)
end)

T["gate 4: o erro do diagrama inválido também fica no cache"] = native_case(function()
  open_preview(doc({ "```mermaid", "flowchart TD", "  A -->", "```" }))
  eq(child.lua_get("_G.stats().misses"), 1)
  child.cmd("Deckle close")
  child.cmd("Deckle open")
  eq(child.lua_get("_G.stats()").misses, 1)
  eq(child.lua_get("_G.stats()").hits, 1)
end)

-- ---------------------------------------------------------------------------------------
-- Gate 5
-- ---------------------------------------------------------------------------------------

--- As linhas do preview que o mapa atribui ao bloco `index` (1-indexado entre os de topo).
---@param index integer
---@return string[]
local function block_lines(index)
  local entry = child.lua_get(("_G.state().map[%d]"):format(index))
  local lines = preview_lines()
  return vim.list_slice(lines, entry.preview_start + 1, entry.preview_end)
end

T["gate 5: charset = ascii produz o diagrama sem byte fora do ASCII"] = native_case(function()
  child.lua([[require("deckle").setup({ charset = "ascii" })]])
  open_preview(doc(SEQUENCE, FLOW))
  for index = 1, 2 do
    local art = block_lines(index)
    eq(#art > 3, true)
    eq(table.concat(art, "\n"):find("[\128-\255]"), nil)
  end
  eq(has(preview_lines(), "Alice"), true)
  eq(has(preview_lines(), "+"), true)
end)

T["gate 5: o mesmo diagrama em Unicode tem byte fora do ASCII (o caso acima não é vazio)"] = native_case(
  function()
    child.lua([[require("deckle").setup({ charset = "unicode" })]])
    open_preview(doc(SEQUENCE))
    eq(table.concat(block_lines(1), "\n"):find("[\128-\255]") ~= nil, true)
  end
)

-- ---------------------------------------------------------------------------------------
-- Largura
-- ---------------------------------------------------------------------------------------

T["linha mais larga que a janela fica inteira, sem corte nem reticências"] = native_case(function()
  local wide = {
    "```mermaid",
    "flowchart LR",
    "  A[Primeiro passo do processo] --> B[Segundo passo do processo]",
    "  B --> C[Terceiro passo do processo] --> D[Quarto passo do processo]",
    "```",
  }
  child.lua([[require("deckle").setup({ width = 40 })]])
  open_preview(doc(wide))
  local lines = preview_lines()
  local widest = 0
  for _, line in ipairs(lines) do
    widest = math.max(widest, child.fn.strdisplaywidth(line))
  end
  -- O desenho passou da janela e nada foi cortado: o merman quebra os rótulos dentro dos nós,
  -- então o que se confere é a borda direita do último nó e o rótulo que cabe numa linha.
  eq(widest > 40, true)
  eq(has(lines, "Primeiro"), true)
  eq(has(lines, "Quarto passo do processo │"), true)
  eq(has(lines, "…"), false)
  eq(has(lines, "mermaid:"), false)
  eq(child.lua_get("vim.wo[_G.state().win].wrap"), false)
end)

T["dentro de um quote o desenho sai prefixado pela borda do quote"] = native_case(function()
  local quoted = vim.tbl_map(function(line)
    return "> " .. line
  end, FLOW)
  open_preview(quoted)
  local lines = preview_lines()
  eq(#lines > 3, true)
  for _, line in ipairs(lines) do
    eq(vim.startswith(line, "│"), true)
  end
  eq(has(lines, "Start"), true)
  eq(has(lines, "Stop"), true)
end)

-- ---------------------------------------------------------------------------------------
-- Carregador com o binário de verdade
-- ---------------------------------------------------------------------------------------

T["native.path aponta para o .so: carrega por package.loadlib e desenha"] = native_case(function()
  child.lua(([[require("deckle").setup({ native = { path = %q } })]]):format(so_path))
  open_preview(doc(SEQUENCE))
  eq(has(preview_lines(), "Hello Bob"), true)
  local status = child.lua_get([[require("deckle.native").status()]])
  eq(status.source, "config")
  eq(status.path, so_path)
end)

T["sem o require, o carregador acha o binário pelo instalador (info().path)"] = native_case(
  function()
    child.lua([[
    local real_require = require
    _G.require = function(name)
      if name == "deckle_native" then
        error("module 'deckle_native' not found:\n\tno file (hidden by the test)", 0)
      end
      return real_require(name)
    end
  ]])
    open_preview(doc(SEQUENCE))
    eq(has(preview_lines(), "Hello Bob"), true)
    local status = child.lua_get([[require("deckle.native").status()]])
    eq(status.source, "install")
    eq(status.path, so_path)
  end
)

T["diagram_ty do bloco pula a detecção; um tipo desconhecido degrada, não lança"] = native_case(
  function()
    local out = child.lua_get([[(function()
    local mermaid = require("deckle.render.mermaid")
    local ctx = { width = 80, charset = "unicode", indent = 0, depth = 0 }
    local src = { "sequenceDiagram", "  A->>B: oi" }
    local typed = mermaid.render({ kind = "code", lang = "mermaid", lines = src, diagram_ty = "sequence" }, ctx)
    local wrong = mermaid.render({ kind = "code", lang = "mermaid", lines = src, diagram_ty = "nope" }, ctx)
    return { typed = typed, wrong = wrong }
  end)()]])
    eq(#out.typed > 3, true)
    eq(out.typed[1]:find("mermaid:", 1, true), nil)
    eq(has(out.wrong, "mermaid: parse error"), true)
  end
)

-- ---------------------------------------------------------------------------------------
-- Checkhealth
-- ---------------------------------------------------------------------------------------

T["checkhealth: camada 1 com os 14 tipos suportados lidos do crate"] = native_case(function()
  child.lua([[vim.env.XDG_DATA_HOME = vim.fn.tempname()]])
  child.cmd("checkhealth deckle")
  local text = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  eq(text:match("layer 1 —") ~= nil, true)
  eq(text:match("layer 0 —") ~= nil, false)
  eq(text:match("native mermaid renderer loaded %(deckle_native v") ~= nil, true)
  eq(text:match("supported diagram types %(14%)") ~= nil, true)
  eq(text:match("flowchart") ~= nil, true)
  eq(text:match("sequence") ~= nil, true)
  eq(text:match("WARNING") ~= nil, false)
  eq(text:match("ERROR") ~= nil, false)
end)

return T
