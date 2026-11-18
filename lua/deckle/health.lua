--- `:checkhealth deckle`.
---
--- ADR-0004 exige que o checkhealth diga em que camada o usuário está e o que falta para
--- subir, senão degradação silenciosa vira bug reportado. A camada 1 é detectada de verdade:
--- o checkhealth pede o módulo ao `deckle.native` e diz o motivo quando ele não carrega.

local M = {}

--- Piso de versão. É a única versão medida (ver docs/validation.md); 0.10 é suposição.
local MIN_NVIM = "0.11.0"

--- Parsers que o render de Markdown vai precisar. Os dois vêm do core do Neovim, não do
--- nvim-treesitter — é o princípio 1 da arquitetura.
local REQUIRED_PARSERS = { "markdown", "markdown_inline" }

local health = vim.health

local function check_neovim()
  health.start("Neovim")

  local version = vim.version()
  local current = string.format("%d.%d.%d", version.major, version.minor, version.patch)

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("version " .. current .. " (minimum " .. MIN_NVIM .. ")")
  else
    health.error(
      "version " .. current .. " is below the minimum " .. MIN_NVIM,
      { "upgrade Neovim to " .. MIN_NVIM .. " or newer" }
    )
  end
end

---@param lang string
---@return boolean ok, string|nil err
local function parser_available(lang)
  -- `language.add` é o teste certo: não depende da extensão do arquivo (.so, .dll) nem de
  -- adivinhar o diretório do parser.
  local ok, err = pcall(vim.treesitter.language.add, lang)
  if ok then
    return true
  end
  return false, tostring(err)
end

local function check_parsers()
  health.start("Treesitter parsers")

  for _, lang in ipairs(REQUIRED_PARSERS) do
    local ok, err = parser_available(lang)
    if ok then
      health.ok("`" .. lang .. "` parser found")
    else
      health.error("`" .. lang .. "` parser not found: " .. (err or "unknown reason"), {
        "this parser ships with Neovim 0.11 — a broken install or a stale runtime path",
        "or install it with `:TSInstall " .. lang .. "` if you use nvim-treesitter",
      })
    end
  end
end

local function check_config()
  health.start("Configuration")

  local config = require("deckle.config")

  if config.configured then
    health.ok("`setup()` was called")
  else
    health.info("`setup()` was not called — running on defaults")
  end

  local options = config.options
  health.info(
    string.format(
      "split=%s  width=%s  charset=%s  sync=%s  debounce_ms=%d",
      options.split,
      options.width and tostring(options.width) or "window",
      options.charset,
      options.sync,
      options.debounce_ms
    )
  )
end

--- Há um binário que deveria ter carregado? Com `native.path` ou um binário no disco, uma falha
--- de carga é acionável (`warn`); sem nenhum dos dois, camada 0 é só o estado normal (`info`).
---@return boolean
local function binary_expected()
  if require("deckle.config").options.native.path then
    return true
  end
  local ok, info = pcall(function()
    return require("deckle.install").info()
  end)
  return ok and info.origin ~= "missing"
end

--- A camada em que o plugin está **agora**, de verdade: pede o módulo ao `deckle.native`, que o
--- carrega (uma vez por sessão) e guarda o motivo se não conseguir. É a única pergunta do
--- checkhealth que carrega o `.so`; a seção seguinte só lê o disco.
local function check_layer()
  health.start("Capability layer")

  local native = require("deckle.native")
  local ok, mod = pcall(native.get)
  local status = native.status()

  if ok and status.loaded and mod then
    local from = status.path or "the runtimepath"
    health.ok(
      string.format(
        "layer 1 — native mermaid renderer loaded (deckle_native v%s, %s: %s)",
        status.version or "?",
        status.source or "?",
        from
      )
    )
    local types_ok, types = pcall(mod.supported_types)
    if types_ok and type(types) == "table" then
      table.sort(types)
      health.info(
        string.format("supported diagram types (%d): %s", #types, table.concat(types, ", "))
      )
    else
      health.warn("could not list the supported diagram types: " .. tostring(types))
    end
    health.info("a diagram that fails to render falls back to a plain code block, only that one")
    return
  end

  health.ok("layer 0 — Markdown preview, no external dependency")
  health.info("mermaid blocks render as plain code blocks on layer 0")

  local reason = status.reason
  if not ok then
    reason = "could not load the native module: " .. tostring(mod)
  end
  if not status.enabled then
    health.info("layer 1 (native mermaid) is off: " .. (reason or "disabled"))
  elseif binary_expected() then
    -- Há um binário (no disco ou por `native.path`) e ele não carregou: isso o usuário
    -- consegue consertar, ao contrário de não ter binário nenhum.
    health.warn("layer 1 (native mermaid) is unavailable: " .. (reason or "unknown reason"), {
      "check that the file is a deckle_native build for this platform and Neovim",
      "reinstall with `:Deckle install` (restart Neovim afterwards) or `make native`",
      "set `native.enabled = false` to stop trying",
    })
  else
    health.info("layer 1 (native mermaid) needs the native binary, see below")
  end
end

--- Onde está o binário nativo e de onde veio (fase 8). Só lê o disco: carregar o `.so` é do
--- `check_layer`. Com o binário ausente, diz o motivo e o que fazer; é aqui, e não num erro
--- durante o `:Deckle install`, que a camada 0 aparece.
local function check_native_binary()
  health.start("Native binary")

  local config = require("deckle.config")
  local override = config.options.native.path
  if override then
    health.info("`native.path` is set: " .. override)
  end
  if not config.options.native.enabled then
    health.info("`native.enabled` is false — the binary is not loaded")
  end

  local ok, info = pcall(function()
    return require("deckle.install").info()
  end)
  if not ok then
    health.warn("could not inspect the installed binary: " .. tostring(info))
    return
  end

  if info.origin == "release" then
    health.ok(
      string.format(
        "installed from a release (v%s, %s): %s",
        info.version or "?",
        info.target or "?",
        info.path
      )
    )
  elseif info.origin == "build" then
    health.ok(string.format("built locally (%s): %s", info.source or "cargo", info.path))
  else
    health.info("missing — " .. (info.reason or "not installed"))
    health.info("mermaid blocks render as plain code blocks until a binary is installed")
    local advice = {
      "run `:Deckle install` (downloads the release binary, falls back to `cargo build`)",
      "or run `make native` in the plugin directory (needs cargo)",
    }
    if info.last_error then
      health.warn("the last install attempt failed: " .. info.last_error, advice)
    else
      health.info("to install it: " .. advice[1] .. "; " .. advice[2])
    end
    return
  end

  if info.last_error then
    health.info("a later install attempt failed: " .. info.last_error)
  end
end

function M.check()
  check_neovim()
  check_parsers()
  check_config()
  check_layer()
  check_native_binary()
end

return M
