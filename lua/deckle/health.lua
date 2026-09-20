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
  -- o que detectar. Quando a fase 7 entrar, isto vira detecção de verdade.
  health.ok("layer 0 — Markdown preview, no external dependency")
  health.info("mermaid blocks render as plain code blocks on layer 0")
  -- `info`, não `warn`: nada está quebrado e não há nada que o usuário possa fazer a
  -- respeito neste build. O warn fica para a fase 7, quando existir um `.so` que possa
  -- falhar em carregar — aí sim é acionável.
  health.info("layer 1 (native mermaid) is not available in this build")
end

function M.check()
  check_neovim()
  check_parsers()
  check_config()
  check_layer()
end

return M
