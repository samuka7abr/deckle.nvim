--- Detecção de capacidade do terminal (fase 9, camada 2).
---
--- Responde uma pergunta só: este terminal desenha imagem por protocolo gráfico? ADR-0004 manda
--- o padrão conservador, porque a detecção por variável de ambiente é traiçoeira: o `TERM` de
--- dentro do tmux é do tmux (ou, pior, um `xterm-kitty` que alguém configurou à mão), o SSH leva
--- o `TERM` mas não leva o terminal, e nada aqui consulta o terminal de verdade. **Na dúvida, sem
--- gráfico.** Toda a detecção é uma função pura de uma tabela de ambiente (`detect`), e é essa a
--- que os testes forjam; `current` é só a cola com o ambiente real.
---
--- # Resultado
---
--- ```lua
--- { layer = 0|1|2, graphics = "kitty"|"iterm2"|"sixel"|nil, reason = "...",
---   terminal = "kitty"|"ghostty"|"wezterm"|"iterm2"|"foot"|...|nil,
---   multiplexer = "tmux"|"screen"|nil, remote = boolean }
--- ```
---
--- * `layer` é o que o **terminal** deixa subir na escada do ADR-0004, não o plugin inteiro (a
---   camada do `deckle_native` é outro assunto): `0` terminal burro (`TERM` ausente, `dumb` ou
---   `linux`: nem borda Unicode é garantida); `1` terminal de texto; `2` há protocolo gráfico.
--- * `graphics` é o protocolo que o terminal fala, não o que o deckle sabe desenhar. Só `"kitty"`
---   vira imagem hoje (ver `deckle.image`); `"iterm2"` e `"sixel"` são detectados e caem em
---   texto alternativo.
--- * `reason` é uma linha em inglês, para o `:checkhealth`, com o motivo da decisão: o que foi
---   reconhecido ou o que barrou.
--- * `multiplexer` e `remote` dizem por que caminho os bytes chegam ao terminal: o tmux exige
---   embrulhar o escape (`deckle.image` faz), e numa sessão remota o terminal não lê o arquivo
---   desta máquina (a imagem tem de ir inteira pelo tty).
---
--- # O que barra
---
--- * **Terminal burro:** `TERM` ausente, `dumb` ou `linux`. Vale mesmo que haja outras pistas.
--- * **GNU screen:** não repassa protocolo gráfico.
--- * **tmux:** só com `allow-passthrough` confirmado (`opts.tmux_passthrough == true`) **e** o
---   terminal de fora reconhecido por uma variável que não seja `TERM`/`TERM_PROGRAM`, que no tmux
---   são do tmux ou mentem. `KITTY_WINDOW_ID` e afins podem estar velhos (o tmux guarda o ambiente
---   de quem o iniciou), então isso ainda é heurística, e o motivo diz isso.
--- * **SSH** (`SSH_CONNECTION`, `SSH_CLIENT` ou `SSH_TTY`): o `TERM` viaja, o resto não, e nada
---   garante o terminal do outro lado.
---
--- `opts.optin` (a opção `images.enabled = true`) levanta as duas últimas barras: é o usuário
--- assumindo o risco. Não inventa um protocolo: terminal que não foi reconhecido continua sem
--- gráfico.

local M = {}

---@class deckle.Caps
---@field layer 0|1|2
---@field graphics "kitty"|"iterm2"|"sixel"|nil
---@field reason string
---@field terminal string|nil
---@field multiplexer "tmux"|"screen"|nil
---@field remote boolean

---@class deckle.CapsOpts
---@field optin boolean|nil             `images.enabled = true`: assume SSH e tmux por conta do usuário
---@field tmux_passthrough boolean|nil  `allow-passthrough` do tmux confirmado ligado

---@param env table<string, string>
---@param name string
---@return boolean
local function has(env, name)
  local value = env[name]
  return value ~= nil and value ~= ""
end

---@param env table<string, string>
---@return boolean
local function wezterm_env(env)
  for key in pairs(env) do
    if type(key) == "string" and key:find("^WEZTERM_") then
      return true
    end
  end
  return false
end

--- Quem está do outro lado do tty, e que protocolo ele fala. `trust_term` liga as pistas que
--- vêm de `TERM` e `TERM_PROGRAM`: dentro do tmux elas não valem.
---@param env table<string, string>
---@param trust_term boolean
---@return string|nil terminal, "kitty"|"iterm2"|"sixel"|nil graphics, string|nil evidence
local function identify(env, trust_term)
  local term = env.TERM or ""
  local program = env.TERM_PROGRAM or ""

  if has(env, "KITTY_WINDOW_ID") then
    return "kitty", "kitty", "KITTY_WINDOW_ID is set"
  end
  if trust_term and term == "xterm-kitty" then
    return "kitty", "kitty", "TERM=xterm-kitty"
  end

  -- O ghostty fala o protocolo do kitty, Unicode placeholders inclusive.
  if has(env, "GHOSTTY_RESOURCES_DIR") or has(env, "GHOSTTY_BIN_DIR") then
    return "ghostty", "kitty", "GHOSTTY_* is set"
  end
  if trust_term and (term == "xterm-ghostty" or program == "ghostty") then
    return "ghostty",
      "kitty",
      term == "xterm-ghostty" and "TERM=xterm-ghostty" or "TERM_PROGRAM=ghostty"
  end

  -- O WezTerm fala o protocolo do iTerm2 (e um subconjunto do kitty, sem Unicode placeholders).
  if wezterm_env(env) then
    return "wezterm", "iterm2", "WEZTERM_* is set"
  end
  if trust_term and program == "WezTerm" then
    return "wezterm", "iterm2", "TERM_PROGRAM=WezTerm"
  end

  -- `LC_TERMINAL` é o que o iTerm2 manda pelo SSH, e `ITERM_SESSION_ID` o que ele põe no ambiente.
  if env.LC_TERMINAL == "iTerm2" then
    return "iterm2", "iterm2", "LC_TERMINAL=iTerm2"
  end
  if has(env, "ITERM_SESSION_ID") then
    return "iterm2", "iterm2", "ITERM_SESSION_ID is set"
  end
  if trust_term and program == "iTerm.app" then
    return "iterm2", "iterm2", "TERM_PROGRAM=iTerm.app"
  end

  if trust_term then
    for _, name in ipairs({ "foot", "mlterm", "contour" }) do
      if term:find("^" .. name) then
        return name, "sixel", "TERM=" .. term
      end
    end
    if term:find("sixel", 1, true) then
      return "sixel", "sixel", "TERM=" .. term
    end
  end
  return nil, nil, nil
end

---@param env table<string, string>
---@return "tmux"|"screen"|nil
local function multiplexer_of(env)
  if has(env, "TMUX") then
    return "tmux"
  end
  if has(env, "STY") then
    return "screen"
  end
  local term = env.TERM or ""
  if term:find("^tmux") then
    return "tmux"
  end
  if term:find("^screen") then
    return "screen"
  end
  return nil
end

--- Decide, a partir de `env`, o que o terminal faz. Pura: não lê o ambiente nem roda nada.
---@param env table<string, string>|nil  variáveis de ambiente (nome -> valor); ausente é `{}`
---@param opts deckle.CapsOpts|nil
---@return deckle.Caps
function M.detect(env, opts)
  env = env or {}
  opts = opts or {}

  local term = env.TERM
  local mux = multiplexer_of(env)
  local remote = has(env, "SSH_CONNECTION") or has(env, "SSH_CLIENT") or has(env, "SSH_TTY")

  ---@type deckle.Caps
  local caps = { layer = 1, graphics = nil, reason = "", multiplexer = mux, remote = remote }

  if term == nil or term == "" or term == "dumb" or term == "linux" then
    caps.layer = 0
    caps.reason = term == nil and "dumb terminal: TERM is not set"
      or term == "" and "dumb terminal: TERM is empty"
      or ("dumb terminal: TERM=" .. term)
    return caps
  end

  if mux == "screen" then
    caps.reason = "inside GNU screen, which does not forward graphics protocols"
    return caps
  end

  -- Dentro do tmux o `TERM` é do tmux; só as variáveis do terminal de fora valem, e elas podem
  -- estar velhas.
  local terminal, graphics, evidence = identify(env, mux ~= "tmux")

  if mux == "tmux" and not opts.optin and opts.tmux_passthrough ~= true then
    caps.reason = "inside tmux and `allow-passthrough` is not confirmed on "
      .. "(`tmux set -g allow-passthrough on`, or set `images.enabled = true` to assume it)"
    return caps
  end
  if remote and not opts.optin then
    caps.reason = "SSH session: the local terminal cannot be confirmed from here "
      .. "(set `images.enabled = true` to assume it supports graphics)"
    return caps
  end

  if not graphics then
    caps.reason = mux == "tmux"
        and "inside tmux and the outer terminal is not identified " .. "(TERM belongs to tmux; no KITTY_WINDOW_ID, GHOSTTY_*, WEZTERM_* or LC_TERMINAL)"
      or ("no graphics protocol identified (TERM=" .. term .. ")")
    return caps
  end

  caps.layer = 2
  caps.graphics = graphics
  caps.terminal = terminal
  local notes = {}
  if mux == "tmux" then
    notes[#notes + 1] = opts.tmux_passthrough == true and "through tmux passthrough"
      or "tmux passthrough assumed by `images.enabled = true`"
    notes[#notes + 1] = "outer terminal inferred from a variable that may be stale"
  end
  if remote then
    notes[#notes + 1] = "SSH session assumed by `images.enabled = true`"
  end
  caps.reason = string.format("%s (%s)", terminal, evidence)
    .. (#notes > 0 and ("; " .. table.concat(notes, "; ")) or "")
  return caps
end

-- ---------------------------------------------------------------------------------------
-- Ambiente real
-- ---------------------------------------------------------------------------------------

---@type table<string, deckle.Caps>
local memo = {}

---@type { env: table<string, string>, tmux_passthrough: boolean|nil }|nil
local override = nil

--- Pergunta ao tmux se `allow-passthrough` está ligado. `false` para qualquer dúvida: tmux
--- ausente do PATH, versão antiga demais para ter a opção, erro, demora.
---@return boolean
local function tmux_allows_passthrough()
  for _, args in ipairs({
    { "tmux", "show-options", "-Apv", "allow-passthrough" },
    { "tmux", "show-options", "-gv", "allow-passthrough" },
  }) do
    local ok, result = pcall(function()
      return vim.system(args, { text = true, timeout = 1000 }):wait()
    end)
    if ok and result and result.code == 0 then
      local value = vim.trim(result.stdout or "")
      return value == "on" or value == "all"
    end
  end
  return false
end

--- Detecção sobre o ambiente real (`vim.fn.environ()`), memoizada: o render chama a cada
--- repintura e o tmux custa um processo. `opts.refresh` ignora o que está guardado (o
--- `:checkhealth` faz isso, para refletir um `allow-passthrough` ligado depois).
---@param opts { optin: boolean|nil, refresh: boolean|nil }|nil
---@return deckle.Caps
function M.current(opts)
  opts = opts or {}
  local key = opts.optin and "optin" or "auto"
  if memo[key] and not opts.refresh then
    return memo[key]
  end

  local env, passthrough
  if override then
    env, passthrough = override.env, override.tmux_passthrough
  else
    env = vim.fn.environ()
    if has(env, "TMUX") then
      passthrough = tmux_allows_passthrough()
    end
  end
  memo[key] = M.detect(env, { optin = opts.optin, tmux_passthrough = passthrough })
  return memo[key]
end

--- Esquece o que `current` guardou.
function M.reset()
  memo = {}
end

--- Gancho de teste: faz `current` ler `env` (e o `allow-passthrough` dado) em vez do ambiente
--- real, sem rodar o tmux. `nil` desfaz. Sem isto, a suíte dependeria do terminal de quem a roda.
---@param env table<string, string>|nil
---@param tmux_passthrough boolean|nil
function M.set_override(env, tmux_passthrough)
  override = env and { env = env, tmux_passthrough = tmux_passthrough } or nil
  memo = {}
end

return M
