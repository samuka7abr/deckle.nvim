-- Testes de `deckle.preview` (fase 2): buffer, janela, ciclo de vida e re-render.
--
-- Cada caso roda num Neovim filho: janelas, buffers e autocmds são estado global, e o gate 3
-- (fechar e reabrir não vaza) é uma contagem desse estado.
--
-- Os eventos que o preview escuta (`TextChanged`, `InsertLeave`, `WinResized`) têm um caso com
-- tecla de verdade (`child.type_keys`): num Neovim dirigido por RPC eles só disparam quando o
-- laço principal volta a andar, e o que o põe para andar é uma tecla digitada. Os demais casos
-- os entregam com `nvim_exec_autocmds`, que é determinístico e basta, porque os handlers
-- ignoram o conteúdo do evento e leem o estado da janela e do buffer.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.columns = 120
      child.o.lines = 40
      child.lua([==[
        -- `vim.notify` coletado: o preview avisa por notify em vez de lançar.
        _G.notes = {}
        vim.notify = function(msg, level)
          table.insert(_G.notes, { msg = msg, level = level })
        end

        -- Os três eventos `User` que o preview emite, na ordem.
        _G.events = {}
        vim.api.nvim_create_autocmd("User", {
          pattern = { "DeckleOpen", "DeckleRender", "DeckleClose" },
          callback = function(args)
            table.insert(_G.events, {
              name = args.match,
              src_ok = args.data.src_buf == _G.src,
              buf_ok = type(args.data.buf) == "number",
              has_win = args.data.win ~= nil,
            })
          end,
        })

        _G.state = function()
          return require("deckle.preview").state(_G.src)
        end

        -- Tudo que o gate 3 conta.
        _G.census = function()
          local out = {
            bufs = #vim.api.nvim_list_bufs(),
            wins = #vim.api.nvim_list_wins(),
            tabs = #vim.api.nvim_list_tabpages(),
            autocmds = 0,
            deckle_autocmds = 0,
            live_autocmds = 0,
          }
          for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
            out.autocmds = out.autocmds + 1
            local group = au.group_name or ""
            if group:find("^deckle_") then
              out.deckle_autocmds = out.deckle_autocmds + 1
            end
            if group:find("^deckle_preview_") then
              out.live_autocmds = out.live_autocmds + 1
            end
          end
          return out
        end

        -- Espera `cond` por até 2 s e devolve se ela valeu.
        _G.wait_for = function(cond)
          return vim.wait(2000, cond, 10)
        end
      ]==])
    end,
    post_once = child.stop,
  },
})

-- ---------------------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------------------

--- Cria um buffer fonte com `lines` na janela atual e o guarda em `_G.src`.
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

local function use_readme()
  child.cmd("edit README.md")
  child.lua("_G.src = vim.api.nvim_get_current_buf()")
end

---@return table
local function state()
  return child.lua_get("_G.state()")
end

---@param s table estado do preview
---@return string[]
local function preview_lines(s)
  return child.api.nvim_buf_get_lines(s.buf, 0, -1, false)
end

---@return table
local function census()
  return child.lua_get("_G.census()")
end

---@param name string
---@return string[] eventos já emitidos, na ordem
local function event_names()
  return child.lua_get([[vim.tbl_map(function(e) return e.name end, _G.events)]])
end

---@param n integer
local function wait_renders(n)
  eq(child.lua_get(("_G.wait_for(function() return _G.state().renders >= %d end)"):format(n)), true)
end

local LONG = string.rep("palavra ", 60)

-- ---------------------------------------------------------------------------------------
-- Gate 1: abrir o README do projeto
-- ---------------------------------------------------------------------------------------

T["abrir"] = new_set()

T["abrir"]["`:Deckle open` no README.md do projeto renderiza sem erro"] = function()
  use_readme()
  child.cmd("Deckle open")

  eq(child.lua_get("_G.notes"), {})
  local s = state()
  eq(s.renders, 1)
  eq(type(s.win), "number")
  eq(child.lua_get("vim.api.nvim_win_get_buf(" .. s.win .. ") == " .. s.buf), true)

  local lines = preview_lines(s)
  eq(#lines > 20, true)
  eq(lines[1], "deckle.nvim")
  eq(table.concat(lines, "\n"):find("somente-leitura", 1, true) ~= nil, true)

  -- A marcação sumiu do texto. O README mostra Markdown de exemplo dentro de uma cerca, que
  -- aparece cru de propósito, então só vale o que vem antes da primeira moldura de código.
  local prose = {}
  for _, line in ipairs(lines) do
    if line:find("^╭") or line:find("^%+%-") then
      break
    end
    prose[#prose + 1] = line
  end
  local text = table.concat(prose, "\n")
  eq(#prose > 5, true)
  eq(text:find("# deckle.nvim", 1, true), nil)
  eq(text:find("**", 1, true), nil)

  -- O texto tem cor: o H1 do README.
  local extmarks = child.lua_get(
    ([[vim.api.nvim_buf_get_extmarks(%d, require("deckle.preview").ns, 0, -1, { details = true })]]):format(
      s.buf
    )
  )
  local groups = {}
  for _, extmark in ipairs(extmarks) do
    groups[extmark[4].hl_group] = true
  end
  eq(groups.DeckleH1, true)
  eq(groups.DeckleH2, true)
  eq(groups.DeckleStrong, true)
  eq(groups.DeckleLink, true)
end

T["abrir"]["charset = ascii: o preview não tem byte fora do ASCII nas bordas e marcadores"] = function()
  child.lua([[require("deckle").setup({ charset = "ascii" })]])
  use_source({ "# T", "", "- a", "", "> q", "", "---" })
  child.cmd("Deckle open")
  local text = table.concat(preview_lines(state()), "\n")
  eq(text:find("[\128-\255]"), nil)
end

T["abrir"]["a janela de preview abre ao lado e o foco continua no fonte"] = function()
  use_source({ "# t" })
  local source_win = child.api.nvim_get_current_win()
  child.cmd("Deckle open")
  local s = state()
  eq(child.api.nvim_get_current_win(), source_win)
  eq(child.lua_get("#vim.api.nvim_list_wins()"), 2)
  -- vsplit: o preview fica à direita, na mesma linha.
  local source_pos = child.api.nvim_win_get_position(source_win)
  local preview_pos = child.api.nvim_win_get_position(s.win)
  eq(preview_pos[1], source_pos[1])
  eq(preview_pos[2] > source_pos[2], true)
end

T["abrir"]["largura do render é a da janela de preview"] = function()
  use_source({ "# t", "", LONG })
  child.cmd("Deckle open")
  local s = state()
  eq(s.width, child.api.nvim_win_get_width(s.win))
  for _, line in ipairs(preview_lines(s)) do
    eq(child.fn.strdisplaywidth(line) <= s.width, true)
  end
end

T["abrir"]["a janela de preview tem as opções de leitura"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  local win = state().win
  local function wo(name)
    return child.lua_get(("vim.wo[%d].%s"):format(win, name))
  end
  eq(wo("number"), false)
  eq(wo("relativenumber"), false)
  eq(wo("signcolumn"), "no")
  eq(wo("wrap"), false)
end

T["abrir"]["buffer sem nome também abre"] = function()
  child.cmd("enew")
  child.lua(
    "vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'texto' }); _G.src = vim.api.nvim_get_current_buf()"
  )
  child.cmd("Deckle open")
  eq(child.lua_get("_G.notes"), {})
  eq(preview_lines(state()), { "texto" })
end

T["abrir"]["dois fontes com o mesmo nome de arquivo abrem os dois previews"] = function()
  child.lua([[
    local a = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(a, "/nonexistent/a/x.md")
    vim.api.nvim_buf_set_lines(a, 0, -1, false, { "# a" })
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(b, "/nonexistent/b/x.md")
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "# b" })
    _G.a, _G.b = a, b
    require("deckle.preview").open(a)
    require("deckle.preview").open(b)
  ]])
  eq(child.lua_get("_G.notes"), {})
  local sa = child.lua_get([[require("deckle.preview").state(_G.a)]])
  local sb = child.lua_get([[require("deckle.preview").state(_G.b)]])
  eq(sa.renders, 1)
  eq(sb.renders, 1)
  eq(sa.buf ~= sb.buf, true)
  eq(preview_lines(sa)[1], "a")
  eq(preview_lines(sb)[1], "b")
end

-- ---------------------------------------------------------------------------------------
-- Gate 2: o preview rejeita edição
-- ---------------------------------------------------------------------------------------

T["somente leitura"] = new_set()

T["somente leitura"]["o buffer de preview rejeita edição"] = function()
  use_source({ "# t", "", "texto" })
  child.cmd("Deckle open")
  local s = state()
  local before = preview_lines(s)

  eq(child.lua_get(("vim.bo[%d].modifiable"):format(s.buf)), false)
  eq(child.lua_get(("vim.bo[%d].buftype"):format(s.buf)), "nofile")
  eq(child.lua_get(("vim.bo[%d].buflisted"):format(s.buf)), false)
  eq(child.lua_get(("vim.bo[%d].swapfile"):format(s.buf)), false)
  eq(child.lua_get(("vim.bo[%d].filetype"):format(s.buf)), "deckle")

  -- Pela API.
  eq(
    child.lua_get(("(pcall(vim.api.nvim_buf_set_lines, %d, 0, 1, false, { 'x' }))"):format(s.buf)),
    false
  )
  eq(
    child.lua_get(("(pcall(vim.api.nvim_buf_set_text, %d, 0, 0, 0, 1, { 'x' }))"):format(s.buf)),
    false
  )

  -- Pelo modo normal, dentro da janela de preview.
  child.api.nvim_set_current_win(s.win)
  eq(child.lua_get([[(pcall(vim.cmd, "normal! ggdd"))]]), false)
  eq(child.lua_get([[(pcall(vim.cmd, "normal! Ixis"))]]), false)
  eq(child.lua_get([[(pcall(vim.cmd, "normal! ggVGd"))]]), false)

  eq(preview_lines(s), before)
end

T["somente leitura"]["continua nomodifiable depois de cada re-render"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  local s = state()
  child.cmd("Deckle refresh")
  child.cmd("Deckle refresh")
  eq(state().renders, 3)
  eq(child.lua_get(("vim.bo[%d].modifiable"):format(s.buf)), false)
end

T["somente leitura"]["a janela de preview não fica com o buffer errado"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  local s = state()
  eq(child.lua_get(("vim.api.nvim_win_get_buf(%d)"):format(s.win)), s.buf)
end

-- ---------------------------------------------------------------------------------------
-- Gate 3: fechar e reabrir não vaza buffer nem autocmd
-- ---------------------------------------------------------------------------------------

T["vazamento"] = new_set()

T["vazamento"]["fechar e reabrir não vaza buffer, janela nem autocmd, por contagem"] = function()
  use_source({ "# t", "", "texto" })

  -- Um ciclo completo primeiro: o que sobra dele (o buffer de preview escondido, o autocmd
  -- que o descarta e o `ColorScheme` dos highlights) é o piso, e não pode crescer.
  child.cmd("Deckle open")
  local first = state()
  child.cmd("Deckle close")
  local floor = census()
  eq(floor.live_autocmds, 0)
  eq(floor.wins, 1)

  for _ = 1, 5 do
    child.cmd("Deckle open")
    local open = census()
    eq(open.wins, 2)
    -- Aberto, há autocmds vivos a mais: a contagem está medindo alguma coisa.
    eq(open.live_autocmds > 0, true)
    eq(open.autocmds > floor.autocmds, true)
    eq(state().buf, first.buf) -- o mesmo buffer, reaproveitado

    child.cmd("Deckle close")
    eq(census(), floor)
  end
end

T["vazamento"]["alternar com toggle também não vaza"] = function()
  use_source({ "# t" })
  child.cmd("Deckle toggle")
  child.cmd("Deckle toggle")
  local floor = census()
  for _ = 1, 4 do
    child.cmd("Deckle toggle")
    child.cmd("Deckle toggle")
    eq(census(), floor)
  end
end

T["vazamento"]["fechar a janela por conta própria também limpa os autocmds vivos"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  local s = state()
  child.api.nvim_set_current_win(s.win)
  child.cmd("close")

  eq(state().win, nil)
  eq(census().live_autocmds, 0)
  eq(census().wins, 1)
  eq(event_names(), { "DeckleOpen", "DeckleRender", "DeckleClose" })

  -- E o preview reabre normalmente.
  child.cmd("Deckle open")
  eq(census().wins, 2)
  eq(state().buf, s.buf)
end

T["vazamento"]["fechar com um render agendado não renderiza depois"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 100 })]])
  use_source({ "# t" })
  child.cmd("Deckle open")
  child.lua([[vim.api.nvim_exec_autocmds("TextChanged", { buffer = _G.src })]])
  child.cmd("Deckle close")
  child.lua("vim.wait(400)")
  eq(state().renders, 1)
  eq(child.lua_get("_G.notes"), {})
end

T["vazamento"]["apagar o buffer fonte descarta o preview inteiro"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  local s = state()
  child.cmd("bwipeout! " .. s.src_buf)

  eq(child.lua_get("_G.state()"), vim.NIL)
  eq(child.lua_get(("vim.api.nvim_buf_is_valid(%d)"):format(s.buf)), false)
  local after = census()
  eq(after.wins, 1)
  eq(after.deckle_autocmds, 0)
end

T["vazamento"]["apagar o buffer de preview à mão descarta o estado"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  local s = state()
  child.cmd("bwipeout! " .. s.buf)

  eq(child.lua_get("_G.state()"), vim.NIL)
  local after = census()
  eq(after.wins, 1)
  eq(after.deckle_autocmds, 0)
  -- O fonte segue intacto e o preview abre de novo do zero.
  eq(child.lua_get("vim.api.nvim_buf_is_valid(_G.src)"), true)
  child.cmd("Deckle open")
  eq(state().renders, 1)
  eq(census().wins, 2)
end

-- ---------------------------------------------------------------------------------------
-- Gate 5: o fonte é intocável (ADR-0003)
-- ---------------------------------------------------------------------------------------

T["buffer fonte"] = new_set()

T["buffer fonte"]["termina sem nenhum extmark do deckle e sem ter sido alterado"] = function()
  use_readme()
  local tick = child.lua_get("vim.api.nvim_buf_get_changedtick(_G.src)")
  local options = child.lua_get(
    [[{ vim.bo[_G.src].modifiable, vim.bo[_G.src].modified, vim.bo[_G.src].readonly, vim.wo.conceallevel }]]
  )

  child.cmd("Deckle open")
  child.cmd("Deckle refresh")
  child.lua([[vim.api.nvim_exec_autocmds("TextChanged", { buffer = _G.src })]])
  wait_renders(3)
  child.cmd("Deckle close")
  child.cmd("Deckle open")

  local s = state()
  local report = child.lua(([[
    local report = { deckle_namespaces = 0, src_extmarks = 0, preview_extmarks = 0 }
    for name, id in pairs(vim.api.nvim_get_namespaces()) do
      if name:find("^deckle") then
        report.deckle_namespaces = report.deckle_namespaces + 1
        report.src_extmarks = report.src_extmarks + #vim.api.nvim_buf_get_extmarks(_G.src, id, 0, -1, {})
        report.preview_extmarks = report.preview_extmarks + #vim.api.nvim_buf_get_extmarks(%d, id, 0, -1, {})
      end
    end
    return report
  ]]):format(s.buf))

  eq(report.deckle_namespaces >= 1, true)
  eq(report.src_extmarks, 0)
  -- O mesmo laço, no buffer de preview, acha marcas: sem isso o zero acima não prova nada.
  eq(report.preview_extmarks > 0, true)

  eq(child.lua_get("vim.api.nvim_buf_get_changedtick(_G.src)"), tick)
  eq(
    child.lua_get(
      [[{ vim.bo[_G.src].modifiable, vim.bo[_G.src].modified, vim.bo[_G.src].readonly, vim.wo.conceallevel }]]
    ),
    options
  )
end

-- ---------------------------------------------------------------------------------------
-- Re-render
-- ---------------------------------------------------------------------------------------

T["re-render"] = new_set()

T["re-render"]["TextChanged do fonte renderiza de novo, uma vez só para uma rajada"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 50 })]])
  use_source({ "# antes" })
  child.cmd("Deckle open")
  eq(preview_lines(state())[1], "antes")

  child.lua([[
    vim.api.nvim_buf_set_lines(_G.src, 0, -1, false, { "# depois" })
    for _ = 1, 5 do
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = _G.src })
    end
  ]])
  wait_renders(2)
  child.lua("vim.wait(300)")
  eq(state().renders, 2) -- cinco disparos, um render
  eq(preview_lines(state())[1], "depois")
end

T["re-render"]["editar o fonte de verdade, com teclas, renderiza de novo (TextChanged e InsertLeave reais)"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 20 })]])
  use_source({ "# titulo", "", "texto" })
  child.cmd("Deckle open")
  eq(state().renders, 1)

  -- Modo normal: `x` apaga um caractere e o laço principal dispara `TextChanged`.
  child.type_keys("G", "x")
  wait_renders(2)
  local lines = preview_lines(state())
  eq(lines[#lines], "exto")

  -- Modo insert: nada renderiza enquanto se digita (não há `TextChangedI`), e sair do insert
  -- renderiza o que foi digitado.
  child.type_keys("A", "!!")
  child.lua("vim.wait(150)")
  eq(state().renders, 2)
  child.type_keys("<Esc>")
  wait_renders(3)
  lines = preview_lines(state())
  eq(lines[#lines], "exto!!")
end

T["re-render"]["InsertLeave do fonte também renderiza de novo"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 20 })]])
  use_source({ "# antes" })
  child.cmd("Deckle open")

  child.lua([[
    vim.api.nvim_buf_set_lines(_G.src, 0, -1, false, { "# saiu do insert" })
    vim.api.nvim_exec_autocmds("InsertLeave", { buffer = _G.src })
  ]])
  wait_renders(2)
  eq(preview_lines(state())[1], "saiu do insert")
end

T["re-render"]["debounce_ms = 0 renderiza na próxima volta do laço"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 0 })]])
  use_source({ "# antes" })
  child.cmd("Deckle open")
  child.lua([[
    vim.api.nvim_buf_set_lines(_G.src, 0, -1, false, { "# agora" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = _G.src })
  ]])
  wait_renders(2)
  eq(preview_lines(state())[1], "agora")
end

T["re-render"]["editar outro buffer não renderiza o preview"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 20 })]])
  use_source({ "# t" })
  child.cmd("Deckle open")
  child.lua([[
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = other })
  ]])
  child.lua("vim.wait(200)")
  eq(state().renders, 1)
end

T["re-render"]["redimensionar a janela renderiza de novo na largura nova"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 20 })]])
  use_source({ "# t", "", LONG })
  child.cmd("Deckle open")
  local s = state()
  local lines_before = #preview_lines(s)

  child.api.nvim_win_set_width(s.win, 30)
  child.lua([[vim.api.nvim_exec_autocmds("WinResized", {})]])
  wait_renders(2)

  local after = state()
  eq(after.width, 30)
  eq(#preview_lines(after) > lines_before, true)
  for _, line in ipairs(preview_lines(after)) do
    eq(child.fn.strdisplaywidth(line) <= 30, true)
  end
end

T["re-render"]["`WinResized` de verdade, depois de uma tecla no laço principal"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 20 })]])
  use_source({ "# t", "", LONG })
  child.cmd("Deckle open")
  child.api.nvim_win_set_width(state().win, 28)
  -- O Neovim só avalia o redimensionamento quando o laço principal volta a andar.
  child.type_keys("<Esc>")
  wait_renders(2)
  eq(state().width, 28)
end

T["re-render"]["`VimResized` também"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 20 })]])
  use_source({ "# t", "", LONG })
  child.cmd("Deckle open")
  child.api.nvim_win_set_width(state().win, 25)
  child.lua([[vim.api.nvim_exec_autocmds("VimResized", {})]])
  wait_renders(2)
  eq(state().width, 25)
end

T["re-render"]["resize que não muda a largura não renderiza"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 20 })]])
  use_source({ "# t" })
  child.cmd("Deckle open")
  child.lua([[vim.api.nvim_exec_autocmds("WinResized", {})]])
  child.lua("vim.wait(200)")
  eq(state().renders, 1)
end

T["re-render"]["config.width vence a janela e ajusta o vsplit"] = function()
  child.lua([[require("deckle").setup({ width = 33 })]])
  use_source({ "# t", "", LONG })
  child.cmd("Deckle open")
  local s = state()
  eq(s.width, 33)
  eq(child.api.nvim_win_get_width(s.win), 33)
  for _, line in ipairs(preview_lines(s)) do
    eq(child.fn.strdisplaywidth(line) <= 33, true)
  end
end

T["re-render"]["a posição de leitura sobrevive ao render"] = function()
  -- Sem a sincronia (fase 3): com ela, o render realinha o preview ao cursor do fonte.
  child.lua([[require("deckle").setup({ sync = "off" })]])
  local lines = {}
  for i = 1, 120 do
    lines[#lines + 1] = "parágrafo " .. i
    lines[#lines + 1] = ""
  end
  use_source(lines)
  child.cmd("Deckle open")
  local s = state()
  child.api.nvim_win_set_cursor(s.win, { 60, 0 })
  child.cmd("Deckle refresh")
  eq(child.api.nvim_win_get_cursor(s.win)[1], 60)
end

T["re-render"]["fonte que encolhe não deixa a janela de preview com cursor inválido"] = function()
  local lines = {}
  for i = 1, 80 do
    lines[#lines + 1] = "parágrafo " .. i
    lines[#lines + 1] = ""
  end
  use_source(lines)
  child.cmd("Deckle open")
  local s = state()
  child.api.nvim_win_set_cursor(s.win, { 100, 0 })
  child.lua([[vim.api.nvim_buf_set_lines(_G.src, 0, -1, false, { "# curto" })]])
  child.cmd("Deckle refresh")
  eq(child.lua_get("_G.notes"), {})
  eq(child.api.nvim_win_get_cursor(s.win)[1] <= #preview_lines(s), true)
end

-- ---------------------------------------------------------------------------------------
-- Mapa e eventos
-- ---------------------------------------------------------------------------------------

T["estado"] = new_set()

T["estado"]["expõe o mapa preview -> fonte do último render"] = function()
  use_source({ "# a", "", "par um", "", "- x", "- y" })
  child.cmd("Deckle open")
  local s = state()
  eq(s.map, {
    { preview_start = 0, preview_end = 2, src_start = 0, src_end = 1 },
    { preview_start = 3, preview_end = 4, src_start = 2, src_end = 3 },
    { preview_start = 5, preview_end = 7, src_start = 4, src_end = 6 },
  })
  -- E cada entrada aponta para o texto certo do preview.
  eq(preview_lines(s)[s.map[2].preview_start + 1], "par um")
end

T["estado"]["o mapa acompanha a edição do fonte"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 20 })]])
  use_source({ "# a", "", "par" })
  child.cmd("Deckle open")
  child.lua([[
    vim.api.nvim_buf_set_lines(_G.src, 0, 0, false, { "intro", "" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = _G.src })
  ]])
  wait_renders(2)
  local map = state().map
  eq(#map, 3)
  eq(map[1], { preview_start = 0, preview_end = 1, src_start = 0, src_end = 1 })
  eq(map[2].src_start, 2)
end

T["estado"]["`state()` de um buffer sem preview é nil"] = function()
  use_source({ "# t" })
  eq(child.lua_get("_G.state()"), vim.NIL)
end

T["estado"]["depois de fechar, `win` some e o resto fica"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  child.cmd("Deckle close")
  local s = state()
  eq(s.win, nil)
  eq(type(s.buf), "number")
  eq(s.renders, 1)
  eq(#s.map, 1)
end

T["estado"]["eventos User: abrir, renderizar e fechar, com os dados"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  eq(event_names(), { "DeckleOpen", "DeckleRender" })
  child.cmd("Deckle refresh")
  child.cmd("Deckle close")
  eq(event_names(), { "DeckleOpen", "DeckleRender", "DeckleRender", "DeckleClose" })

  local events = child.lua_get("_G.events")
  for _, event in ipairs(events) do
    eq(event.src_ok, true)
    eq(event.buf_ok, true)
  end
  eq(events[1].has_win, true)
  eq(events[2].has_win, true)
  eq(events[4].has_win, false)
end

-- ---------------------------------------------------------------------------------------
-- Comandos
-- ---------------------------------------------------------------------------------------

T["comandos"] = new_set()

T["comandos"]["toggle abre e fecha; sem argumento é toggle"] = function()
  use_source({ "# t" })
  child.cmd("Deckle toggle")
  eq(census().wins, 2)
  child.cmd("Deckle toggle")
  eq(census().wins, 1)
  child.cmd("Deckle")
  eq(census().wins, 2)
  child.cmd("Deckle")
  eq(census().wins, 1)
end

T["comandos"]["open com o preview já aberto não cria outra janela e leva o foco"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  local s = state()
  child.cmd("Deckle open")
  eq(census().wins, 2)
  eq(child.api.nvim_get_current_win(), s.win)
  eq(state().renders, 2)
end

T["comandos"]["dentro do preview, os comandos valem para o fonte dele"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  local s = state()
  child.api.nvim_set_current_win(s.win)

  child.cmd("Deckle open")
  eq(census().wins, 2)
  child.cmd("Deckle refresh")
  eq(state().renders, 3)
  child.cmd("Deckle toggle")
  eq(census().wins, 1)
  eq(state().win, nil)

  child.cmd("Deckle open")
  child.api.nvim_set_current_win(state().win)
  child.cmd("Deckle close")
  eq(census().wins, 1)
end

T["comandos"]["close e refresh sem preview avisam, não lançam"] = function()
  use_source({ "# t" })
  child.cmd("Deckle close")
  child.cmd("Deckle refresh")
  local notes = child.lua_get("_G.notes")
  eq(#notes, 2)
  eq(notes[1].msg:match("no open preview") ~= nil, true)
  eq(notes[2].msg:match("no open preview") ~= nil, true)
end

T["comandos"]["split = split abre embaixo"] = function()
  child.lua([[require("deckle").setup({ split = "split" })]])
  use_source({ "# t" })
  local source_win = child.api.nvim_get_current_win()
  child.cmd("Deckle open")
  local source_pos = child.api.nvim_win_get_position(source_win)
  local preview_pos = child.api.nvim_win_get_position(state().win)
  eq(preview_pos[2], source_pos[2])
  eq(preview_pos[1] > source_pos[1], true)
end

T["comandos"]["split = tab abre numa aba nova e fechar a descarta"] = function()
  child.lua([[require("deckle").setup({ split = "tab" })]])
  use_source({ "# t" })
  child.cmd("Deckle open")
  eq(census().tabs, 2)
  eq(child.api.nvim_get_current_win(), state().win)
  eq(preview_lines(state())[1], "t")

  local floor_before = census()
  child.cmd("Deckle close")
  eq(census().tabs, 1)
  child.cmd("Deckle open")
  child.cmd("Deckle close")
  eq(census().bufs, floor_before.bufs)
  eq(census().live_autocmds, 0)
end

T["comandos"]["a janela que não coube avisa em vez de lançar"] = function()
  child.lua([[require("deckle").setup({ split = "split" })]])
  use_source({ "# t" })
  -- Sem altura para mais uma janela, o split falha (E36).
  child.o.lines = 3
  child.cmd("Deckle open")
  local notes = child.lua_get("_G.notes")
  eq(#notes >= 1, true)
  eq(notes[1].msg:match("could not open the preview window") ~= nil, true)
  eq(census().live_autocmds, 0)
end

-- ---------------------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------------------

T["highlights"] = new_set()

local LINKS = {
  DeckleH1 = "Title",
  DeckleH2 = "Title",
  DeckleH3 = "Title",
  DeckleH4 = "Title",
  DeckleH5 = "Title",
  DeckleH6 = "Title",
  DeckleCodeInline = "String",
  DeckleLink = "Underlined",
  DeckleImage = "Special",
  DeckleCode = "ColorColumn",
  DeckleQuote = "Comment",
  DeckleBullet = "Special",
  DeckleRule = "Comment",
  DeckleHtml = "Comment",
  DeckleError = "WarningMsg",
}

T["highlights"]["os grupos existem e linkam a grupos padrão"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  for name, target in pairs(LINKS) do
    eq(child.lua_get(("vim.api.nvim_get_hl(0, { name = %q }).link"):format(name)), target)
  end
  eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = "DeckleStrong" }).bold]]), true)
  eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = "DeckleEmphasis" }).italic]]), true)
end

T["highlights"]["um grupo do usuário definido antes vence o default"] = function()
  child.lua([[vim.api.nvim_set_hl(0, "DeckleH1", { fg = 0xff0000, bold = true })]])
  use_source({ "# t" })
  child.cmd("Deckle open")
  eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = "DeckleH1" }).fg]]), 0xff0000)
  eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = "DeckleH1" }).link]]), vim.NIL)
  -- O vizinho que ele não tocou continua no default.
  eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = "DeckleH2" }).link]]), "Title")
end

T["highlights"]["sobrevivem a `:colorscheme`"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  child.cmd("colorscheme default")
  eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = "DeckleH2" }).link]]), "Title")
  eq(child.lua_get([[vim.api.nvim_get_hl(0, { name = "DeckleStrong" }).bold]]), true)
end

T["highlights"]["abrir várias vezes não duplica o autocmd de ColorScheme"] = function()
  use_source({ "# t" })
  child.cmd("Deckle open")
  child.cmd("Deckle close")
  local n = child.lua_get([[#vim.api.nvim_get_autocmds({ group = "DeckleHighlights" })]])
  child.cmd("Deckle open")
  child.cmd("Deckle close")
  eq(child.lua_get([[#vim.api.nvim_get_autocmds({ group = "DeckleHighlights" })]]), n)
  eq(n, 1)
end

return T
