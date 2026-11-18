-- Gates 2 e 3 da fase 9, com o preview de verdade: sem protocolo gráfico a imagem é texto
-- alternativo e nada mais muda; fechar o preview apaga as imagens do terminal. Mais a integração
-- com o ciclo de vida do preview e com a sincronia de scroll.
--
-- Cada caso roda num Neovim filho. O `writer` do filho junta os bytes em `_G.written` (nada vai
-- ao terminal real) e a detecção de capacidade é forjada por `caps.set_override`.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h")

local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.o.columns = 120
      child.o.lines = 40
      child.lua(
        [==[
          local tests_dir = ...
          _G.fixture = dofile(tests_dir .. "/png_fixture.lua")

          _G.written = {}
          require("deckle.image").set_writer(function(data)
            table.insert(_G.written, data)
          end)
          require("deckle.caps").set_override({ TERM = "xterm-kitty", KITTY_WINDOW_ID = "1" })

          _G.notes = {}
          vim.notify = function(msg, level)
            table.insert(_G.notes, { msg = msg, level = level })
          end

          _G.state = function()
            return require("deckle.preview").state(_G.src)
          end
          _G.wait_for = function(cond)
            return vim.wait(2000, cond, 10)
          end
          _G.bytes = function()
            return table.concat(_G.written)
          end
        ]==],
        { tests_dir }
      )
    end,
    post_once = child.stop,
  },
})

-- ---------------------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------------------

local ESC = "\27"

--- Abre `doc.md` num diretório novo, com `lines`, e o guarda em `_G.src`. Cria `pic.png`
--- (400 x 200) ao lado, que com a janela de 120 colunas vira 40 x 10 células.
---@param lines string[]
local function use_doc(lines)
  child.lua(
    [[
      local lines = ...
      _G.dir = vim.fn.tempname()
      vim.fn.mkdir(_G.dir, "p")
      _G.fixture.write(_G.dir .. "/pic.png", 400, 200)
      vim.cmd("edit " .. vim.fn.fnameescape(_G.dir .. "/doc.md"))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      vim.bo.filetype = "markdown"
      _G.src = vim.api.nvim_get_current_buf()
    ]],
    { lines }
  )
end

local DOC = { "# Título", "", "![foto](pic.png)", "", "texto depois" }

---@return table
local function state()
  return child.lua_get("_G.state()")
end

---@return string[]
local function preview_lines()
  return child.api.nvim_buf_get_lines(state().buf, 0, -1, false)
end

---@return string todos os bytes que o writer recebeu
local function bytes()
  return child.lua_get("_G.bytes()")
end

---@param n integer
local function wait_renders(n)
  eq(child.lua_get(("_G.wait_for(function() return _G.state().renders >= %d end)"):format(n)), true)
end

--- O id que o writer transmitiu pela última vez.
---@return integer
local function sent_id()
  local id
  for found in bytes():gmatch("a=t,f=100,t=%a,i=(%d+),") do
    id = tonumber(found)
  end
  return id
end

---@param text string
---@param pattern string
---@return integer
local function count(text, pattern)
  local _, n = text:gsub(pattern, "")
  return n
end

local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

-- ---------------------------------------------------------------------------------------
-- Com protocolo: a imagem entra no preview
-- ---------------------------------------------------------------------------------------

T["com kitty"] = new_set()

T["com kitty"]["`:Deckle open` reserva as linhas, escreve o buffer de placeholders e transmite"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  eq(child.lua_get("_G.notes"), {})

  local s = state()
  -- título (2 linhas com o sublinhado), vazia, 10 da imagem, vazia, texto.
  local lines = preview_lines()
  eq(#lines, 2 + 1 + 10 + 1 + 1)
  eq(lines[#lines], "texto depois")
  for row = 4, 13 do
    eq(vim.startswith(lines[row], PLACEHOLDER), true)
    eq(child.fn.strdisplaywidth(lines[row]), 40)
  end
  eq(s.map[2], { preview_start = 3, preview_end = 13, src_start = 2, src_end = 3 })

  -- Os bytes: uma transmissão por caminho e um posicionamento do tamanho reservado.
  local id = sent_id()
  eq(id ~= nil, true)
  local text = bytes()
  eq(count(text, "a=t,f=100,t=f,i=" .. id .. ",q=2;"), 1)
  eq(count(text, "a=p,U=1,i=" .. id .. ",c=40,r=10,C=1,q=2"), 1)
  eq(count(text, "d=I"), 0)
end

T["com kitty"]["cada linha de placeholder leva o grupo de cor com o id, e o grupo tem o id na cor"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  local s = state()
  local id = sent_id()

  local extmarks = child.lua_get(
    ([[vim.api.nvim_buf_get_extmarks(%d, require("deckle.preview").ns, { 3, 0 }, { 12, -1 }, { details = true })]]):format(
      s.buf
    )
  )
  local rows = {}
  for _, extmark in ipairs(extmarks) do
    if extmark[4].hl_group == "DeckleImg" .. id then
      rows[extmark[2]] = true
    end
  end
  for row = 3, 12 do
    eq({ row, rows[row] }, { row, true })
  end
  local hl = child.lua_get(([[vim.api.nvim_get_hl(0, { name = "DeckleImg%d" })]]):format(id))
  eq(hl.fg, id)
  eq(hl.ctermfg, id)
end

T["com kitty"]["editar o texto e re-renderizar não retransmite a imagem"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  local before = bytes()
  eq(before ~= "", true)

  child.lua([[vim.api.nvim_buf_set_lines(_G.src, 4, 5, false, { "outro texto" })]])
  child.lua([[vim.api.nvim_exec_autocmds("TextChanged", { buffer = _G.src })]])
  wait_renders(2)
  eq(preview_lines()[#preview_lines()], "outro texto")
  eq(bytes(), before)
end

T["com kitty"]["`:Deckle refresh` retransmite, com o mesmo id: o terminal pode ter perdido a imagem"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  local id = sent_id()
  local first = bytes()

  child.cmd("Deckle refresh")
  eq(sent_id(), id)
  eq(bytes(), first .. first)
end

T["com kitty"]["a imagem some do documento: o render seguinte a apaga"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  local id = sent_id()

  child.lua([[vim.api.nvim_buf_set_lines(_G.src, 2, 4, false, {})]])
  child.lua([[vim.api.nvim_exec_autocmds("TextChanged", { buffer = _G.src })]])
  wait_renders(2)
  eq(count(bytes(), "a=d,d=I,i=" .. id .. ",q=2"), 1)
  eq(child.lua_get([[require("deckle.image").placements(_G.src)]]), {})
  -- Título (com o sublinhado, em qualquer charset), linha em branco e o texto: sem as 10 linhas.
  local lines = preview_lines()
  eq(#lines, 4)
  eq({ lines[1], lines[3], lines[4] }, { "Título", "", "texto depois" })
end

T["com kitty"]["janela mais estreita: a imagem encolhe, ganha outro id e a antiga é apagada"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  local old = sent_id()

  child.lua([[vim.api.nvim_win_set_width(_G.state().win, 30)]])
  child.lua([[vim.api.nvim_exec_autocmds("WinResized", {})]])
  wait_renders(2)

  local new = sent_id()
  eq(new ~= old, true)
  local text = bytes()
  eq(count(text, "a=d,d=I,i=" .. old .. ",q=2"), 1)
  eq(count(text, "a=p,U=1,i=" .. new .. ",c=30,r=8,C=1,q=2"), 1)
  local placements = child.lua_get([[require("deckle.image").placements(_G.src)]])
  eq(#placements, 1)
  eq({ placements[1].cols, placements[1].rows }, { 30, 8 })
end

T["com kitty"]["a sincronia de scroll anda sobre o bloco da imagem"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  local s = state()
  local src_win = child.api.nvim_get_current_win()

  -- Cursor do fonte na linha da imagem (3): o preview vai para a primeira linha reservada.
  child.api.nvim_win_set_cursor(src_win, { 3, 0 })
  child.lua([[vim.api.nvim_exec_autocmds("CursorMoved", { buffer = _G.src })]])
  eq(child.api.nvim_win_get_cursor(s.win)[1], s.map[2].preview_start + 1)

  -- Cursor no texto depois da imagem: o preview vai para a última linha, depois das 10.
  child.api.nvim_win_set_cursor(src_win, { 5, 0 })
  child.lua([[vim.api.nvim_exec_autocmds("CursorMoved", { buffer = _G.src })]])
  eq(child.api.nvim_win_get_cursor(s.win)[1], #preview_lines())
end

-- ---------------------------------------------------------------------------------------
-- Gate 3: fechar o preview apaga as imagens
-- ---------------------------------------------------------------------------------------

T["fechar"] = new_set()

---@param id integer
local function expect_deleted(id)
  eq(count(bytes(), "a=d,d=I,i=" .. id .. ",q=2"), 1)
  eq(child.lua_get([[require("deckle.image").placements(_G.src)]]), {})
end

T["fechar"]["`:Deckle close` manda o comando de apagar a imagem e esquece o id"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  local id = sent_id()
  eq(count(bytes(), "d=I"), 0)

  child.cmd("Deckle close")
  expect_deleted(id)
  -- O comando é exatamente o do protocolo.
  eq(
    bytes():sub(-#(ESC .. "_Ga=d,d=I,i=" .. id .. ",q=2" .. ESC .. "\\")),
    ESC .. "_Ga=d,d=I,i=" .. id .. ",q=2" .. ESC .. "\\"
  )
end

T["fechar"]["`:Deckle toggle` fechando também apaga"] = function()
  use_doc(DOC)
  child.cmd("Deckle toggle")
  local id = sent_id()
  child.cmd("Deckle toggle")
  expect_deleted(id)
end

T["fechar"]["fechar a janela do preview por conta própria (`:close`) apaga"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  local id = sent_id()
  child.api.nvim_set_current_win(state().win)
  child.cmd("close")
  expect_deleted(id)
end

T["fechar"]["apagar o buffer fonte com o preview aberto apaga"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  local id = sent_id()
  child.lua([[vim.cmd("bwipeout! " .. _G.src)]])
  eq(count(bytes(), "a=d,d=I,i=" .. id .. ",q=2"), 1)
  eq(child.lua_get([[require("deckle.image").placements(_G.src)]]), {})
end

T["fechar"]["reabrir transmite de novo, e fechar duas vezes não apaga duas"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  local first = sent_id()
  child.cmd("Deckle close")
  child.cmd("Deckle open")
  local second = sent_id()
  eq(count(bytes(), "a=t,f=100,t=f,"), 2)
  eq(second ~= first, true) -- o id que acabou de sair não volta já
  child.cmd("Deckle close")
  eq(count(bytes(), "a=d,d=I"), 2)
  child.cmd("Deckle close") -- já fechado: só avisa
  eq(count(bytes(), "a=d,d=I"), 2)
end

T["fechar"]["sair do Neovim (`VimLeavePre`) apaga o que ficou"] = function()
  use_doc(DOC)
  child.cmd("Deckle open")
  local id = sent_id()
  child.lua([[vim.api.nvim_exec_autocmds("VimLeavePre", { modeline = false })]])
  eq(count(bytes(), "a=d,d=I,i=" .. id .. ",q=2"), 1)
end

T["fechar"]["sem imagem no documento, fechar não escreve nada"] = function()
  use_doc({ "# só texto", "", "um parágrafo" })
  child.cmd("Deckle open")
  child.cmd("Deckle close")
  eq(child.lua_get("_G.written"), {})
end

-- ---------------------------------------------------------------------------------------
-- Gate 2: sem protocolo gráfico, a imagem é texto alternativo e nada mais muda
-- ---------------------------------------------------------------------------------------

T["sem protocolo"] = new_set()

--- O texto do preview e o que o render da camada 0 (sem provedor de imagens) produz para o
--- mesmo documento, na mesma largura.
---@return string[] preview, string[] baseline
local function preview_and_baseline()
  local s = state()
  local baseline = child.lua(
    [[
      local ir = require("deckle.parse").parse(_G.src)
      return require("deckle.render").render(ir, { width = ..., charset = "auto" }).lines
    ]],
    { s.width }
  )
  return child.api.nvim_buf_get_lines(s.buf, 0, -1, false), baseline
end

local NO_GRAPHICS = {
  ["xterm sem pista"] = { TERM = "xterm-256color" },
  ["terminal burro"] = { TERM = "dumb" },
  ["linux console"] = { TERM = "linux" },
  ["tmux mentindo"] = { TERM = "xterm-kitty", TMUX = "/tmp/tmux-1000/default,1,0" },
  ["SSH"] = { TERM = "xterm-kitty", SSH_CONNECTION = "10.0.0.2 5000 10.0.0.1 22" },
  ["iTerm2 (detectado, não desenhado)"] = { TERM = "xterm-256color", TERM_PROGRAM = "iTerm.app" },
  ["WezTerm (detectado, não desenhado)"] = { TERM = "xterm-256color", WEZTERM_PANE = "1" },
  ["sixel (detectado, não desenhado)"] = { TERM = "foot" },
}

T["sem protocolo"]["o preview é idêntico ao render da camada 0 e nada é escrito"] = function()
  for name, env in pairs(NO_GRAPHICS) do
    child.lua([[require("deckle.caps").set_override((...))]], { env })
    use_doc(DOC)
    child.cmd("Deckle open")

    local preview, baseline = preview_and_baseline()
    eq({ name, preview }, { name, baseline })
    eq({ name, preview[4] }, { name, "[image: foto]" })
    eq({ name, child.lua_get("_G.written") }, { name, {} })
    eq({ name, child.lua_get([[require("deckle.image").placements(_G.src)]]) }, { name, {} })
    eq({ name, child.lua_get("_G.notes") }, { name, {} })
    child.cmd("Deckle close")
    eq({ name, child.lua_get("_G.written") }, { name, {} })
  end
end

T["sem protocolo"]["`images.enabled = false` com kitty detectado: o mesmo"] = function()
  child.lua([[require("deckle").setup({ images = { enabled = false } })]])
  use_doc(DOC)
  child.cmd("Deckle open")
  local preview, baseline = preview_and_baseline()
  eq(preview, baseline)
  eq(preview[4], "[image: foto]")
  eq(child.lua_get("_G.written"), {})
end

T["sem protocolo"]["o README do projeto sai igual, com ou sem kitty"] = function()
  child.cmd("edit README.md")
  child.lua("_G.src = vim.api.nvim_get_current_buf()")
  child.cmd("Deckle open")
  local preview, baseline = preview_and_baseline()
  eq(preview, baseline)
  eq(child.lua_get("_G.written"), {})
end

T["sem protocolo"]["`images.enabled = true` assume o SSH: a imagem vai pelo tty, não por caminho"] = function()
  child.lua([[
    require("deckle").setup({ images = { enabled = true } })
    require("deckle.caps").set_override({ TERM = "xterm-kitty", SSH_CONNECTION = "10.0.0.2 5000 10.0.0.1 22" })
  ]])
  use_doc(DOC)
  child.cmd("Deckle open")
  local text = bytes()
  eq(count(text, "t=d"), 1)
  eq(count(text, "t=f"), 0)
  eq(preview_lines()[4]:sub(1, #PLACEHOLDER), PLACEHOLDER)
end

T["sem protocolo"]["dentro do tmux com passthrough confirmado, os escapes saem embrulhados"] = function()
  child.lua([[
    require("deckle.caps").set_override(
      { TERM = "tmux-256color", TMUX = "/tmp/tmux-1000/default,1,0", KITTY_WINDOW_ID = "1" },
      true
    )
  ]])
  use_doc(DOC)
  child.cmd("Deckle open")
  local text = bytes()
  eq(count(text, ESC .. "Ptmux;"), 2)
  eq(vim.startswith(text, ESC .. "Ptmux;"), true)
end

-- ---------------------------------------------------------------------------------------
-- Imagem que não pode ser desenhada: alt text, sem erro (com protocolo ativo)
-- ---------------------------------------------------------------------------------------

T["recusada"] = new_set()

T["recusada"]["inexistente, não-PNG, URL e `data:`: texto alternativo, nada escrito, nenhum erro"] = function()
  use_doc({
    "![a](nao-existe.png)",
    "",
    "![b](foto.jpg)",
    "",
    "![c](https://example.com/c.png)",
    "",
    "![d](falso.png)",
    "",
    "![e](data:image/png;base64,AAAA)",
  })
  child.lua([[
    local fixture = _G.fixture
    fixture.write_raw(_G.dir .. "/foto.jpg", "\255\216\255\224\0\16JFIF\0\1\1")
    fixture.write_raw(_G.dir .. "/falso.png", "isto não é um PNG")
  ]])
  child.cmd("Deckle open")

  eq(preview_lines(), {
    "[image: a]",
    "",
    "[image: b]",
    "",
    "[image: c]",
    "",
    "[image: d]",
    "",
    "[image: e]",
  })
  eq(child.lua_get("_G.written"), {})
  eq(child.lua_get("_G.notes"), {})
end

T["recusada"]["uma recusada não leva as outras junto: só a PNG vira imagem"] = function()
  use_doc({ "![a](nao-existe.png)", "", "![b](pic.png)", "", "![c](foto.jpg)" })
  child.lua([[_G.fixture.write_raw(_G.dir .. "/foto.jpg", "\255\216\255\224\0\16JFIF")]])
  child.cmd("Deckle open")
  local lines = preview_lines()
  eq(lines[1], "[image: a]")
  eq(vim.startswith(lines[3], PLACEHOLDER), true)
  eq(lines[#lines], "[image: c]")
  eq(count(bytes(), "a=t,f=100"), 1)
end

return T
