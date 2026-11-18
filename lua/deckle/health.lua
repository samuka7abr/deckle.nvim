--- `:checkhealth deckle`.
---
--- ADR-0004 exige que o checkhealth diga em que camada o usuário está e o que falta para
--- subir, senão degradação silenciosa vira bug reportado. Nesta fase a camada é sempre 0:
--- não existe `.so`, e o checkhealth não finge detectar um.

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

local function check_layer()
  health.start("Capability layer")

  -- Camada 0 é sempre verdade nesta fase: `deckle.native` não existe ainda, então não há
  -- o que detectar. Quando a fase 7 entrar, isto vira detecção de verdade. O binário em si
  -- (de onde veio, onde está) já é reportado na seção "Native binary", logo abaixo.
  health.ok("layer 0 — Markdown preview, no external dependency")
  health.info("mermaid blocks render as plain code blocks on layer 0")
  -- `info`, não `warn`: nada está quebrado e não há nada que o usuário possa fazer a
  -- respeito neste build. O warn fica para a fase 7, quando existir um `.so` que possa
  -- falhar em carregar — aí sim é acionável.
  health.info("layer 1 (native mermaid) is not wired into the render yet")
end

--- Onde está o binário nativo e de onde veio (fase 8). Só lê o disco: não carrega o `.so`,
--- que é assunto da fase 7. Com o binário ausente, diz o motivo e o que fazer; é aqui, e não
--- num erro durante o `:Deckle install`, que a camada 0 aparece.
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
