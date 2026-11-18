-- Testes de `deckle.caps` (fase 9): a detecção de capacidade do terminal.
--
-- `detect` é função pura de uma tabela de ambiente, então cada caso forja o ambiente inteiro:
-- nenhum depende do terminal de quem roda a suíte. O gate 1 da fase pede kitty, tmux mentindo,
-- SSH e terminal burro; iTerm2, WezTerm e ghostty entram junto. O caminho "tmux com passthrough
-- confirmado" passa por um `tmux` falso no PATH, que exercita a consulta de verdade.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local caps = require("deckle.caps")

local T = new_set({
  hooks = {
    post_case = function()
      caps.set_override(nil)
    end,
  },
})

local TMUX = "/tmp/tmux-1000/default,1234,0"

-- ---------------------------------------------------------------------------------------
-- Terminais que falam um protocolo
-- ---------------------------------------------------------------------------------------

T["kitty"] = new_set()

T["kitty"]["`TERM=xterm-kitty` e `KITTY_WINDOW_ID`: camada 2, protocolo kitty"] = function()
  local result = caps.detect({ TERM = "xterm-kitty", KITTY_WINDOW_ID = "1" })
  eq(result.layer, 2)
  eq(result.graphics, "kitty")
  eq(result.terminal, "kitty")
  eq(result.multiplexer, nil)
  eq(result.remote, false)
  eq(result.reason:find("kitty", 1, true) ~= nil, true)
end

T["kitty"]["só o `TERM`"] = function()
  local result = caps.detect({ TERM = "xterm-kitty" })
  eq(result.graphics, "kitty")
  eq(result.reason:find("TERM=xterm-kitty", 1, true) ~= nil, true)
end

T["kitty"]["só o `KITTY_WINDOW_ID`, com um `TERM` genérico"] = function()
  local result = caps.detect({ TERM = "xterm-256color", KITTY_WINDOW_ID = "7" })
  eq(result.graphics, "kitty")
  eq(result.reason:find("KITTY_WINDOW_ID", 1, true) ~= nil, true)
end

T["kitty"]["variável vazia vale como ausente"] = function()
  local result = caps.detect({ TERM = "xterm-256color", KITTY_WINDOW_ID = "" })
  eq(result.graphics, nil)
  eq(result.layer, 1)
end

T["ghostty"] = new_set()

T["ghostty"]["fala o protocolo do kitty, por qualquer das três pistas"] = function()
  for _, env in ipairs({
    { TERM = "xterm-ghostty" },
    { TERM = "xterm-256color", TERM_PROGRAM = "ghostty" },
    { TERM = "xterm-256color", GHOSTTY_RESOURCES_DIR = "/usr/share/ghostty" },
    { TERM = "xterm-256color", GHOSTTY_BIN_DIR = "/usr/bin" },
  }) do
    local result = caps.detect(env)
    eq(
      { vim.inspect(env), result.graphics, result.terminal },
      { vim.inspect(env), "kitty", "ghostty" }
    )
    eq(result.layer, 2)
  end
end

T["wezterm"] = new_set()

T["wezterm"]["é detectado com o protocolo do iTerm2"] = function()
  for _, env in ipairs({
    { TERM = "xterm-256color", WEZTERM_EXECUTABLE = "/usr/bin/wezterm-gui" },
    { TERM = "xterm-256color", WEZTERM_PANE = "3" },
    { TERM = "xterm-256color", TERM_PROGRAM = "WezTerm" },
  }) do
    local result = caps.detect(env)
    eq(
      { vim.inspect(env), result.graphics, result.terminal },
      { vim.inspect(env), "iterm2", "wezterm" }
    )
    eq(result.layer, 2)
  end
end

T["iterm2"] = new_set()

T["iterm2"]["é detectado por `TERM_PROGRAM`, `LC_TERMINAL` e `ITERM_SESSION_ID`"] = function()
  for _, env in ipairs({
    { TERM = "xterm-256color", TERM_PROGRAM = "iTerm.app" },
    { TERM = "xterm-256color", LC_TERMINAL = "iTerm2" },
    { TERM = "xterm-256color", ITERM_SESSION_ID = "w0t0p0:ABC" },
  }) do
    local result = caps.detect(env)
    eq(
      { vim.inspect(env), result.graphics, result.terminal },
      { vim.inspect(env), "iterm2", "iterm2" }
    )
  end
end

T["sixel"] = new_set()

T["sixel"]["foot, mlterm e contour pelo `TERM`"] = function()
  for _, term in ipairs({
    "foot",
    "foot-extra",
    "mlterm",
    "mlterm-256color",
    "contour",
    "xterm-sixel",
  }) do
    local result = caps.detect({ TERM = term })
    eq({ term, result.graphics, result.layer }, { term, "sixel", 2 })
  end
end

T["terminal de texto"] = new_set()

T["terminal de texto"]["`xterm-256color` sem pista nenhuma é camada 1 e sem gráfico"] = function()
  local result = caps.detect({ TERM = "xterm-256color" })
  eq(result.layer, 1)
  eq(result.graphics, nil)
  eq(result.terminal, nil)
  eq(result.reason:find("no graphics protocol identified", 1, true) ~= nil, true)
end

T["terminal de texto"]["variável de ambiente nenhuma além do `TERM` não lança"] = function()
  eq(caps.detect({ TERM = "alacritty" }).graphics, nil)
  eq(caps.detect({ TERM = "vt100" }).layer, 1)
end

-- ---------------------------------------------------------------------------------------
-- Terminal burro
-- ---------------------------------------------------------------------------------------

T["burro"] = new_set()

T["burro"]["`dumb`, `linux`, `TERM` vazio e `TERM` ausente: camada 0 e nada"] = function()
  for _, env in ipairs({ { TERM = "dumb" }, { TERM = "linux" }, { TERM = "" }, {} }) do
    local result = caps.detect(env)
    eq({ vim.inspect(env), result.layer, result.graphics }, { vim.inspect(env), 0, nil })
    eq(result.reason:find("dumb terminal", 1, true) ~= nil, true)
  end
end

T["burro"]["o `TERM` burro vence as pistas de outro terminal"] = function()
  local result = caps.detect({ TERM = "dumb", KITTY_WINDOW_ID = "1", GHOSTTY_RESOURCES_DIR = "/x" })
  eq(result.layer, 0)
  eq(result.graphics, nil)
end

T["burro"]["`images.enabled = true` não salva um terminal burro"] = function()
  local result = caps.detect({ TERM = "linux", KITTY_WINDOW_ID = "1" }, { optin = true })
  eq(result.layer, 0)
  eq(result.graphics, nil)
end

T["burro"]["ambiente ausente não lança"] = function()
  eq(caps.detect(nil).layer, 0)
  eq(caps.detect(nil, nil).graphics, nil)
end

-- ---------------------------------------------------------------------------------------
-- tmux
-- ---------------------------------------------------------------------------------------

T["tmux"] = new_set()

T["tmux"]["mentindo: `TERM=xterm-kitty` dentro do tmux não vale como kitty"] = function()
  local result = caps.detect({ TERM = "xterm-kitty", TMUX = TMUX })
  eq(result.graphics, nil)
  eq(result.layer, 1)
  eq(result.multiplexer, "tmux")
  eq(result.reason:find("tmux", 1, true) ~= nil, true)
end

T["tmux"]["mentindo, mesmo com o passthrough confirmado: o `TERM` não identifica o terminal de fora"] = function()
  local result = caps.detect({ TERM = "xterm-kitty", TMUX = TMUX }, { tmux_passthrough = true })
  eq(result.graphics, nil)
  eq(result.reason:find("not identified", 1, true) ~= nil, true)
end

T["tmux"]["`TERM_PROGRAM` também é do tmux: não vale"] = function()
  local result = caps.detect(
    { TERM = "screen-256color", TMUX = TMUX, TERM_PROGRAM = "WezTerm" },
    { tmux_passthrough = true }
  )
  eq(result.graphics, nil)
end

T["tmux"]["pista do terminal de fora, sem `allow-passthrough` confirmado: sem gráfico"] = function()
  local env = { TERM = "tmux-256color", TMUX = TMUX, KITTY_WINDOW_ID = "1" }
  for _, opts in ipairs({ {}, { tmux_passthrough = false }, { tmux_passthrough = nil } }) do
    local result = caps.detect(env, opts)
    eq(result.graphics, nil)
    eq(result.layer, 1)
    eq(result.reason:find("allow-passthrough", 1, true) ~= nil, true)
  end
end

T["tmux"]["com o passthrough confirmado e o kitty de fora identificado: kitty, via tmux"] = function()
  local result = caps.detect(
    { TERM = "tmux-256color", TMUX = TMUX, KITTY_WINDOW_ID = "1" },
    { tmux_passthrough = true }
  )
  eq(result.layer, 2)
  eq(result.graphics, "kitty")
  eq(result.multiplexer, "tmux")
  eq(result.reason:find("tmux passthrough", 1, true) ~= nil, true)
  -- A pista pode estar velha, e o motivo diz.
  eq(result.reason:find("stale", 1, true) ~= nil, true)
end

T["tmux"]["a opção `enabled = true` assume o passthrough"] = function()
  local result = caps.detect(
    { TERM = "tmux-256color", TMUX = TMUX, KITTY_WINDOW_ID = "1" },
    { optin = true }
  )
  eq(result.graphics, "kitty")
  eq(result.reason:find("assumed", 1, true) ~= nil, true)
end

T["tmux"]["a opção `enabled = true` não inventa o terminal de fora"] = function()
  local result = caps.detect({ TERM = "tmux-256color", TMUX = TMUX }, { optin = true })
  eq(result.graphics, nil)
end

T["tmux"]["`TERM` de multiplexer sem `$TMUX` (ambiente cortado) conta como tmux"] = function()
  local result = caps.detect({ TERM = "tmux-256color", KITTY_WINDOW_ID = "1" })
  eq(result.multiplexer, "tmux")
  eq(result.graphics, nil)
end

T["tmux"]["GNU screen não repassa gráfico, nem com opt-in"] = function()
  for _, env in ipairs({
    { TERM = "screen-256color", STY = "1234.pts-0.host", KITTY_WINDOW_ID = "1" },
    { TERM = "screen", KITTY_WINDOW_ID = "1" },
  }) do
    local result = caps.detect(env, { optin = true, tmux_passthrough = true })
    eq(
      { vim.inspect(env), result.graphics, result.multiplexer },
      { vim.inspect(env), nil, "screen" }
    )
    eq(result.layer, 1)
  end
end

-- ---------------------------------------------------------------------------------------
-- SSH
-- ---------------------------------------------------------------------------------------

T["ssh"] = new_set()

T["ssh"]["`TERM=xterm-kitty` viaja pelo SSH, mas o terminal não é confirmado: sem gráfico"] = function()
  for _, var in ipairs({ "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY" }) do
    local result = caps.detect({ TERM = "xterm-kitty", [var] = "10.0.0.2 5000 10.0.0.1 22" })
    eq({ var, result.graphics }, { var, nil })
    eq(result.remote, true)
    eq(result.layer, 1)
    eq(result.reason:find("SSH", 1, true) ~= nil, true)
  end
end

T["ssh"]["com opt-in explícito: o protocolo vem do `TERM`, e a sessão é remota"] = function()
  local result = caps.detect(
    { TERM = "xterm-kitty", SSH_CONNECTION = "10.0.0.2 5000 10.0.0.1 22" },
    { optin = true }
  )
  eq(result.layer, 2)
  eq(result.graphics, "kitty")
  eq(result.remote, true)
  eq(result.reason:find("SSH", 1, true) ~= nil, true)
end

T["ssh"]["o opt-in não inventa um protocolo para um `TERM` genérico"] = function()
  local result = caps.detect(
    { TERM = "xterm-256color", SSH_CONNECTION = "10.0.0.2 5000 10.0.0.1 22" },
    { optin = true }
  )
  eq(result.graphics, nil)
  eq(result.remote, true)
end

T["ssh"]["`LC_TERMINAL` (que o iTerm2 manda pelo SSH) identifica o terminal com opt-in"] = function()
  local result = caps.detect(
    { TERM = "xterm-256color", LC_TERMINAL = "iTerm2", SSH_TTY = "/dev/pts/3" },
    { optin = true }
  )
  eq(result.graphics, "iterm2")
end

T["ssh"]["SSH e tmux juntos: as duas barras valem"] = function()
  local env = {
    TERM = "tmux-256color",
    TMUX = TMUX,
    KITTY_WINDOW_ID = "1",
    SSH_CONNECTION = "10.0.0.2 5000 10.0.0.1 22",
  }
  eq(caps.detect(env, { tmux_passthrough = true }).graphics, nil)
  eq(caps.detect(env, { optin = true }).graphics, "kitty")
end

-- ---------------------------------------------------------------------------------------
-- Ambiente real
-- ---------------------------------------------------------------------------------------

T["current"] = new_set()

T["current"]["lê o ambiente forjado e guarda o resultado"] = function()
  caps.set_override({ TERM = "xterm-kitty", KITTY_WINDOW_ID = "1" })
  local first = caps.current()
  eq(first.graphics, "kitty")
  eq(caps.current(), first)
end

T["current"]["`refresh` e `reset` descartam o que estava guardado"] = function()
  caps.set_override({ TERM = "xterm-kitty" })
  local first = caps.current()
  eq(caps.current({ refresh = true }) ~= first, true)
  eq(caps.current({ refresh = true }).graphics, "kitty")
  local kept = caps.current()
  caps.reset()
  eq(caps.current() ~= kept, true)
end

T["current"]["o opt-in tem a própria entrada"] = function()
  caps.set_override({ TERM = "xterm-kitty", SSH_TTY = "/dev/pts/1" })
  eq(caps.current().graphics, nil)
  eq(caps.current({ optin = true }).graphics, "kitty")
  eq(caps.current().graphics, nil)
end

T["current"]["`set_override(nil)` volta ao ambiente real, que não é o forjado"] = function()
  caps.set_override({ TERM = "dumb" })
  local forged = caps.current()
  eq(forged.layer, 0)
  caps.set_override(nil)
  -- O resultado guardado do ambiente forjado não sobrevive à troca.
  eq(caps.current() ~= forged, true)
end

-- ---------------------------------------------------------------------------------------
-- A consulta ao tmux, com um `tmux` falso no PATH (Neovim filho: o PATH é global)
-- ---------------------------------------------------------------------------------------

local child = MiniTest.new_child_neovim()

T["tmux de verdade"] = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
    end,
    post_once = child.stop,
  },
})

--- Instala um `tmux` que roda `body` (shell) e põe só o diretório dele no PATH.
---@param body string
local function fake_tmux(body)
  child.lua(
    [[
      local body = ...
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/tmux"
      local fd = assert(io.open(path, "w"))
      fd:write("#!/bin/sh\n" .. body .. "\n")
      fd:close()
      vim.uv.fs_chmod(path, 493)
      vim.env.PATH = dir
      vim.env.TMUX = "/tmp/tmux-1000/default,1,0"
      vim.env.TERM = "tmux-256color"
      vim.env.KITTY_WINDOW_ID = "1"
      vim.env.SSH_CONNECTION = nil
      vim.env.SSH_CLIENT = nil
      vim.env.SSH_TTY = nil
    ]],
    { body }
  )
end

---@return boolean
local function has_graphics()
  return child.lua_get([[require("deckle.caps").current().graphics ~= nil]])
end

T["tmux de verdade"]["`allow-passthrough on` confirma: kitty, via tmux"] = function()
  fake_tmux("echo on")
  local result = child.lua_get([[require("deckle.caps").current()]])
  eq(result.graphics, "kitty")
  eq(result.multiplexer, "tmux")
end

T["tmux de verdade"]["`allow-passthrough all` também confirma"] = function()
  fake_tmux("echo all")
  eq(has_graphics(), true)
end

T["tmux de verdade"]["`allow-passthrough off`: sem gráfico"] = function()
  fake_tmux("echo off")
  eq(has_graphics(), false)
  local reason = child.lua_get([[require("deckle.caps").current().reason]])
  eq(reason:find("allow-passthrough", 1, true) ~= nil, true)
end

T["tmux de verdade"]["tmux que falha (versão sem a opção): sem gráfico"] = function()
  fake_tmux("echo 'unknown option: allow-passthrough' >&2; exit 1")
  eq(has_graphics(), false)
end

T["tmux de verdade"]["tmux fora do PATH: sem gráfico, sem erro"] = function()
  fake_tmux("echo on")
  child.lua([[vim.env.PATH = vim.fn.tempname()]])
  eq(has_graphics(), false)
end

return T
