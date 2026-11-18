-- A documentação e o exemplo com o `.so` de verdade (fase 10): o Mermaid do `examples/showcase.md`
-- sai desenhado, e a captura do README é a saída real do render, não um desenho de memória.
--
-- Como `tests/native/test_mermaid_native.lua`: sem `lua/deckle_native.so` os casos são **pulados
-- com aviso**, e `DECKLE_REQUIRE_NATIVE=1` (o job `native` da CI, por `scripts/test-native.sh`)
-- transforma o pulo em falha. O que vale sem o `.so` (o showcase degrada com nota, o README tem a
-- captura) está em `tests/test_showcase.lua` e `tests/test_doc.lua`.
--
-- Se o merman mudar a arte de um diagrama, a captura do README envelhece e o caso de baixo falha:
-- é para isso que ele existe. Gere de novo a captura (o README diz como) e revise o diff.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h:h")
local H = dofile(tests_dir .. "/doc_helpers.lua")

local so_path = H.repo_root .. "/lua/deckle_native.so"
local has_so = vim.uv.fs_stat(so_path) ~= nil
local required = vim.env.DECKLE_REQUIRE_NATIVE == "1"

if not has_so and not required then
  io.stderr:write(
    "[deckle] tests/native/test_docs_native.lua: PULADO, lua/deckle_native.so nao existe"
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
      child.lua(
        [==[
          -- `charset = "auto"` vira ASCII com TERM=linux/dumb, que é o que uma CI pode ter.
          vim.env.TERM = "xterm-256color"
          _G.showcase = ...

          _G.state = function()
            return require("deckle.preview").state(_G.src)
          end
        ]==],
        { H.showcase_path }
      )
    end,
    post_once = child.stop,
  },
})

---@param lines string[]
---@param text string
---@return integer quantas linhas contêm `text`
local function count_lines(lines, text)
  local n = 0
  for _, line in ipairs(lines) do
    if line:find(text, 1, true) then
      n = n + 1
    end
  end
  return n
end

T["o showcase desenha a sequência e o fluxograma, e só o pie cai para código"] = native_case(
  function()
    child.lua([[
      vim.cmd("edit " .. vim.fn.fnameescape(_G.showcase))
      _G.src = vim.api.nvim_get_current_buf()
    ]])
    child.cmd("Deckle open")
    eq(child.lua_get([[vim.wait(2000, function() return _G.state().renders >= 1 end, 10)]]), true)
    local lines = child.lua_get([[vim.api.nvim_buf_get_lines(_G.state().buf, 0, -1, false)]])

    -- Desenhados: os participantes e os nós estão lá, com borda, e a fonte do mermaid não.
    eq(count_lines(lines, "Usuario") > 0, true)
    eq(count_lines(lines, ":Deckle open") > 0, true)
    eq(count_lines(lines, "Fonte .md") > 0, true)
    eq(count_lines(lines, "Treesitter") > 0, true)
    eq(count_lines(lines, "sequenceDiagram"), 0)
    eq(count_lines(lines, "flowchart TD"), 0)

    -- O `pie` o crate não cobre: vira código com a nota, e só ele.
    eq(count_lines(lines, "pie title Camadas"), 1)
    eq(count_lines(lines, "mermaid: unsupported diagram"), 1)

    local counts = child.lua_get([[(function()
      local n = { mermaid = 0, note = 0, error = 0 }
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(
        _G.state().buf, require("deckle.preview").ns, 0, -1, { details = true })) do
        local hl = m[4].hl_group
        if hl == "DeckleMermaid" then
          n.mermaid = n.mermaid + 1
        elseif hl == "DeckleCodeNote" then
          n.note = n.note + 1
        elseif hl == "DeckleError" then
          n.error = n.error + 1
        end
      end
      return n
    end)()]])
    eq(counts.mermaid > 0, true)
    eq(counts.note, 1)
    eq(counts.error, 0)
  end
)

T["a captura do README é a saída real do render do fonte que ela mostra"] = native_case(function()
  local source, capture = H.source_and_capture(vim.fn.readfile(H.readme_path), "Como fica")
  eq(source ~= nil and capture ~= nil, true)

  local rendered = child.lua_get(
    [[(function(source, width)
        local ir = require("deckle.parse").parse_lines(source)
        local result = require("deckle.render").render(ir, { width = width, charset = "unicode" })
        return result.lines
      end)(...)]],
    { source, H.CAPTURE_WIDTH }
  )
  eq(H.rtrim(rendered), H.rtrim(capture))

  -- E o Mermaid saiu desenhado, não como código com nota: a captura é da camada 1.
  eq(count_lines(rendered, "┌───────┐") > 0, true)
  eq(count_lines(rendered, "mermaid:"), 0)
end)

return T
