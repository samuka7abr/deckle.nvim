-- `examples/showcase.md` (fase 10): o teste manual do plugin é também um teste automático.
--
-- O arquivo exercita todo tipo de bloco, e a suíte garante que ele continua fazendo isso (o IR tem
-- todos os tipos) e que renderiza sem erro: sem bloco degradado, em qualquer largura e nos dois
-- charsets, e com o preview de verdade. Com protocolo gráfico forjado a imagem do exemplo vira
-- placeholder; sem protocolo, texto alternativo e nenhum byte no terminal.
--
-- O render roda num Neovim filho: o Mermaid carrega o `.so` quando ele existe, e esse estado
-- (`deckle.native` guarda a carga pela sessão) não pode vazar para os outros arquivos de teste.
-- O que depende do `.so` está em `tests/native/test_docs_native.lua`; aqui os casos valem com ou
-- sem ele.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h")
local H = dofile(tests_dir .. "/doc_helpers.lua")

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

          _G.notes = {}
          vim.notify = function(msg, level)
            table.insert(_G.notes, { msg = msg, level = level })
          end

          -- Nada vai ao terminal real: o que o deckle escreveria fica em `_G.written`.
          _G.written = {}
          require("deckle.image").set_writer(function(data)
            table.insert(_G.written, data)
          end)

          _G.source_lines = function()
            return vim.fn.readfile(_G.showcase)
          end

          --- Parse e render do showcase, com o resumo do que saiu.
          _G.render = function(width, charset)
            local ir = require("deckle.parse").parse_lines(_G.source_lines())
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
              last_error = require("deckle.render").last_error,
              text = result.lines,
            }
          end

          _G.state = function()
            return require("deckle.preview").state(_G.src)
          end
          _G.wait_for = function(cond)
            return vim.wait(2000, cond, 10)
          end
        ]==],
        { H.showcase_path }
      )
    end,
    post_once = child.stop,
  },
})

--- Abre o showcase de verdade, como arquivo, para o caminho relativo da imagem resolver.
local function open_showcase()
  child.lua([[
    vim.cmd("edit " .. vim.fn.fnameescape(_G.showcase))
    _G.src = vim.api.nvim_get_current_buf()
  ]])
end

---@return string[]
local function preview_lines()
  return child.lua_get([[vim.api.nvim_buf_get_lines(_G.state().buf, 0, -1, false)]])
end

---@param lines string[]
---@param needle string
---@return integer quantas linhas contêm `needle`
local function count_lines(lines, needle)
  local n = 0
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      n = n + 1
    end
  end
  return n
end

-- ---------------------------------------------------------------------------------------
-- O render
-- ---------------------------------------------------------------------------------------

T["render"] = new_set()

T["render"]["renderiza sem bloco degradado em várias larguras e nos dois charsets"] = function()
  for _, charset in ipairs({ "unicode", "ascii" }) do
    for _, width in ipairs({ 20, 40, 72, 120 }) do
      local r = child.lua_get("_G.render(...)", { width, charset })
      local where = ("largura %d, %s"):format(width, charset)
      eq({ where, r.errors }, { where, 0 })
      eq({ where, r.last_error }, { where })
      eq({ where, r.lines > 150 }, { where, true })
      -- Todo bloco de topo que desenhou algo está no mapa de sync.
      eq({ where, r.mapped }, { where, r.blocks })
    end
  end
end

T["render"]["o preview de verdade abre o showcase sem aviso e deixa o fonte intocado"] = function()
  open_showcase()
  child.cmd("Deckle open")
  eq(child.lua_get([[_G.wait_for(function() return _G.state().renders >= 1 end)]]), true)
  eq(child.lua_get("_G.notes"), {})

  local lines = preview_lines()
  eq(#lines > 150, true)
  eq(lines[1], "Showcase do deckle")
  -- Nenhum bloco degradado: nenhuma marca `DeckleError` no buffer de preview.
  eq(
    child.lua_get([[(function()
      local n = 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(
        _G.state().buf, require("deckle.preview").ns, 0, -1, { details = true })) do
        if m[4].hl_group == "DeckleError" then
          n = n + 1
        end
      end
      return n
    end)()]]),
    0
  )

  -- O cursor passeia pelo documento inteiro sem erro, e o fonte segue igual ao arquivo.
  child.type_keys("G", "gg")
  eq(child.lua_get("_G.notes"), {})
  eq(
    child.lua_get("vim.api.nvim_buf_get_lines(_G.src, 0, -1, false)"),
    H.read("examples/showcase.md")
  )

  child.cmd("Deckle close")
  eq(child.lua_get("_G.notes"), {})
end

-- ---------------------------------------------------------------------------------------
-- O IR: o que o arquivo exercita
-- ---------------------------------------------------------------------------------------

T["cobertura"] = new_set()

T["cobertura"]["o showcase tem todo tipo de bloco, de span e de lista que o render desenha"] = function()
  local seen = child.lua_get([==[(function()
    local acc = {
      kinds = {}, levels = {}, langs = {}, span_kinds = {}, aligns = {}, tasks = {},
      mermaid = {}, ordered = false, unordered = false,
      list_depth = 0, quote_depth = 0, tables = 0, sole_images = 0, images = 0,
    }

    local function spans(list)
      for _, span in ipairs(list or {}) do
        acc.span_kinds[span.kind] = true
        if span.kind == "image" then
          acc.images = acc.images + 1
        end
        spans(span.children)
      end
    end

    local function blank(span)
      return span.kind == "text" and not (span.text or ""):find("%S")
    end

    local walk
    function walk(blocks, quote_depth, list_depth)
      for _, b in ipairs(blocks) do
        acc.kinds[b.kind] = true
        if b.kind == "heading" then
          acc.levels[b.level] = true
          spans(b.spans)
        elseif b.kind == "paragraph" then
          spans(b.spans)
          local only = 0
          for _, span in ipairs(b.spans) do
            if span.kind == "image" then
              only = only + 1
            elseif not blank(span) then
              only = -1000
            end
          end
          if only == 1 then
            acc.sole_images = acc.sole_images + 1
          end
        elseif b.kind == "code" then
          acc.langs[b.lang or "(nenhuma)"] = true
          if b.lang == "mermaid" then
            acc.mermaid[#acc.mermaid + 1] = (b.lines[1] or ""):match("^%S+")
          end
        elseif b.kind == "quote" then
          acc.quote_depth = math.max(acc.quote_depth, quote_depth + 1)
          walk(b.children, quote_depth + 1, list_depth)
        elseif b.kind == "list" then
          acc.list_depth = math.max(acc.list_depth, list_depth + 1)
          if b.ordered then
            acc.ordered = true
          else
            acc.unordered = true
          end
          for _, item in ipairs(b.items) do
            if item.checked ~= nil then
              acc.tasks[tostring(item.checked)] = true
            end
            spans(item.spans)
            walk(item.children, quote_depth, list_depth + 1)
          end
        elseif b.kind == "table" then
          acc.tables = acc.tables + 1
          for _, align in pairs(b.align) do
            acc.aligns[align] = true
          end
          for _, cell in ipairs(b.header) do
            spans(cell)
          end
          for _, row in ipairs(b.rows) do
            for _, cell in ipairs(row) do
              spans(cell)
            end
          end
        end
      end
    end

    walk(require("deckle.parse").parse_lines(_G.source_lines()), 0, 0)

    local function keys(set)
      local out = {}
      for key in pairs(set) do
        out[#out + 1] = tostring(key)
      end
      table.sort(out)
      return out
    end
    acc.kinds, acc.levels, acc.langs = keys(acc.kinds), keys(acc.levels), keys(acc.langs)
    acc.span_kinds, acc.aligns, acc.tasks = keys(acc.span_kinds), keys(acc.aligns), keys(acc.tasks)
    return acc
  end)()]==])

  eq(seen.kinds, { "code", "heading", "html", "list", "paragraph", "quote", "rule", "table" })
  eq(seen.levels, { "1", "2", "3", "4", "5", "6" })
  eq(seen.span_kinds, { "break", "code", "emphasis", "image", "link", "strong", "text" })

  -- Listas: ordenada e não ordenada, de tarefa (as duas), e aninhadas até o quarto nível, que é
  -- onde o marcador volta ao primeiro do ciclo.
  eq({ seen.ordered, seen.unordered }, { true, true })
  eq(seen.tasks, { "false", "true" })
  eq(seen.list_depth >= 4, true)

  -- Citações aninhadas em três níveis.
  eq(seen.quote_depth >= 3, true)

  -- Tabelas com os três alinhamentos.
  eq(seen.tables >= 4, true)
  eq(seen.aligns, { "center", "left", "right" })

  -- Código: com linguagem, sem linguagem e com uma que não existe.
  for _, lang in ipairs({ "lua", "c", "(nenhuma)", "linguagem-inexistente", "mermaid" }) do
    eq({ lang, vim.tbl_contains(seen.langs, lang) }, { lang, true })
  end

  -- Mermaid: sequência e fluxograma (que o crate desenha) e um `pie`, que ele não cobre.
  eq(seen.mermaid, { "sequenceDiagram", "flowchart", "pie" })

  -- Imagem: uma sozinha no parágrafo (a que vira imagem de verdade) e outras que não.
  eq(seen.sole_images, 2)
  eq(seen.images >= 3, true)
end

-- ---------------------------------------------------------------------------------------
-- Mermaid, com ou sem o `.so`
-- ---------------------------------------------------------------------------------------

T["mermaid"] = new_set()

T["mermaid"]["cada bloco ou é desenhado ou degrada com a nota, e o `pie` sempre degrada"] = function()
  local native = child.lua_get([[require("deckle.native").get() ~= nil]])
  local r = child.lua_get("_G.render(...)", { 100, "unicode" })

  local notes = {}
  for _, line in ipairs(r.text) do
    if vim.startswith(line, "mermaid: ") then
      notes[#notes + 1] = line
    end
  end
  eq(count_lines(r.text, "sequenceDiagram") > 0, not native)
  if native then
    -- Os dois diagramas saem desenhados e só o `pie` cai para código, com o motivo.
    eq(r.mermaid > 0, true)
    eq(#notes, 1)
    eq(notes[1]:find("unsupported diagram", 1, true) ~= nil, true)
  else
    -- Camada 0: os três blocos saem como código, cada um com a nota do porquê.
    eq(r.mermaid, 0)
    eq(#notes, 3)
    eq(notes[1]:find("native module unavailable", 1, true) ~= nil, true)
  end
  -- Em qualquer camada, o `pie` é código: a fonte dele está no preview.
  eq(count_lines(r.text, "pie title Camadas"), 1)
end

-- ---------------------------------------------------------------------------------------
-- Imagem: o PNG do exemplo
-- ---------------------------------------------------------------------------------------

T["imagem"] = new_set()

T["imagem"]["o PNG do exemplo é válido, e o cabeçalho diz 200 x 100"] = function()
  local size = child.lua_get([[(function()
    local path = vim.fn.fnamemodify(_G.showcase, ":h") .. "/assets/folha.png"
    local width, height = require("deckle.image.png").size(path)
    return { width, height }
  end)()]])
  eq(size, { 200, 100 })
end

T["imagem"]["com protocolo gráfico, só a imagem sozinha vira placeholder, e fechar a apaga"] = function()
  child.lua(
    [[require("deckle.caps").set_override({ TERM = "xterm-kitty", KITTY_WINDOW_ID = "1" })]]
  )
  open_showcase()
  child.cmd("Deckle open")
  eq(child.lua_get([[_G.wait_for(function() return _G.state().renders >= 1 end)]]), true)
  eq(child.lua_get("_G.notes"), {})

  local lines = preview_lines()
  local placeholder = child.fn.nr2char(0x10EEEE)
  local rows = 0
  for _, line in ipairs(lines) do
    if vim.startswith(line, placeholder) then
      rows = rows + 1
      eq(child.fn.strdisplaywidth(line), 20)
    end
  end
  -- 200 x 100 pixels, na célula suposta de 10 x 20: 20 colunas por 5 linhas.
  eq(rows, 5)
  eq(count_lines(lines, "[image: Uma folha de papel com moldura escura]"), 0)
  -- As outras duas continuam texto alternativo.
  eq(count_lines(lines, "[image: ícone]"), 1)
  eq(count_lines(lines, "[image: Logo remoto, só texto alternativo]"), 1)

  local placements = child.lua_get("require('deckle.image').placements(_G.src)")
  eq(#placements, 1)
  eq({ placements[1].cols, placements[1].rows, placements[1].sent }, { 20, 5, true })
  eq(vim.endswith(placements[1].path, "examples/assets/folha.png"), true)

  local written = table.concat(child.lua_get("_G.written"))
  eq(written:find("a=t,f=100,t=f,i=" .. placements[1].id .. ",", 1, true) ~= nil, true)
  eq(written:find("d=I", 1, true) == nil, true)

  child.cmd("Deckle close")
  written = table.concat(child.lua_get("_G.written"))
  eq(written:find("a=d,d=I,i=" .. placements[1].id, 1, true) ~= nil, true)
end

T["imagem"]["sem protocolo gráfico, a imagem é texto alternativo e nada vai ao terminal"] = function()
  child.lua([[require("deckle.caps").set_override({ TERM = "dumb" })]])
  open_showcase()
  child.cmd("Deckle open")
  eq(child.lua_get([[_G.wait_for(function() return _G.state().renders >= 1 end)]]), true)

  local lines = preview_lines()
  eq(count_lines(lines, "[image: Uma folha de papel com moldura escura]"), 1)
  eq(count_lines(lines, "[image: ícone]"), 1)
  eq(child.lua_get("_G.written"), {})
  eq(child.lua_get("require('deckle.image').placements(_G.src)"), {})
end

return T
