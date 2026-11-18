--- Carregador do módulo nativo `deckle_native` (camada 1). Fase 7 do roadmap.
---
--- O módulo é opcional (ADR-0004): sem ele o plugin inteiro funciona e só o mermaid vira
--- bloco de código cru. Este módulo é quem sabe se ele está ou não disponível, e por quê.
---
--- # Uso
---
--- ```lua
--- local native = require("deckle.native")
--- local mod = native.get()          -- o módulo de Rust, ou nil (camada 0)
--- if mod then
---   local ok, lines = pcall(mod.render, src, opts)
--- end
--- native.status()                   -- retrato para o checkhealth e para teste
--- ```
---
--- # Ordem de carga
---
--- Na primeira chamada de `get()`, nesta ordem, parando no primeiro que carrega:
---
--- 1. `config.native.path`, por `package.loadlib`. **Caminho explícito manda**: se ele está
---    configurado e não carrega, não se cai para os degraus abaixo. Quem aponta um arquivo quer
---    aquele arquivo, e carregar outro em silêncio esconderia o erro de configuração (o motivo
---    vai para o checkhealth). Na dúvida, camada mais baixa (ADR-0004).
--- 2. `require("deckle_native")`, que acha `lua/deckle_native.<ext>` no runtimepath: é o que o
---    `make native` deixa no plugin.
--- 3. O binário que o instalador da fase 8 pôs em `stdpath("data")/deckle/`, o que
---    `deckle.install.info().path` aponta, por `package.loadlib` (no macOS o arquivo é `.so`,
---    não `.dylib`, e o `require` nem sempre o acharia).
---
--- # Regras
---
--- * **Nunca lança.** Toda falha vira o motivo em `status().reason`.
--- * **Nunca tenta de novo na mesma sessão.** O resultado, bom ou ruim, fica guardado: um `.so`
---   que não carregou não vai carregar na segunda tentativa, e refazer o `dlopen` a cada bloco
---   mermaid custaria um acesso a disco por render. `:Deckle install` avisa que é preciso
---   reiniciar o Neovim, e por isso. Mudar `native.path` depois da primeira carga também só vale
---   na próxima sessão.
--- * **`native.enabled = false` é lido a cada chamada**, não guardado: desligar na config
---   devolve `nil` na hora, sem tocar no `.so`, e religar não exige reiniciar.
--- * Não carregamos o módulo ao carregar este arquivo nem no `setup()`: o primeiro bloco mermaid
---   (ou o checkhealth) é quem paga o `dlopen`.

local M = {}

--- Nome do módulo no `package.loaded` e o símbolo de entrada que o mlua exporta.
local MODULE = "deckle_native"
local ENTRY = "luaopen_deckle_native"

---@class deckle.NativeModule
---@field render fun(src: string, opts?: table): string[]
---@field render_ex fun(src: string, opts?: table): { lines: string[], simplified: string|nil, cause: string|nil }|nil  ausente nos módulos mais antigos
---@field supported_types fun(): string[]
---@field version fun(): string

---@class deckle.NativeStatus
---@field enabled boolean        `native.enabled` da config, lido agora
---@field attempted boolean      já houve a tentativa de carga (só `get()` a provoca)
---@field loaded boolean         `get()` devolve o módulo: ligado e carregado
---@field source "config"|"runtimepath"|"install"|nil  de onde veio, quando `loaded`
---@field path string|nil        arquivo carregado, quando se sabe (nil no `require` sem arquivo)
---@field version string|nil     `deckle_native.version()`, quando `loaded`
---@field reason string|nil      quando não está disponível: por quê, em uma linha

---@class deckle.NativeState
---@field attempted boolean
---@field module deckle.NativeModule|nil
---@field source string|nil
---@field path string|nil
---@field version string|nil
---@field reason string|nil

---@return deckle.NativeState
local function fresh()
  return { attempted = false }
end

---@type deckle.NativeState
local state = fresh()

---@return table
local function native_options()
  return require("deckle.config").options.native
end

--- Uma linha só: mensagens do `dlopen` e do `require` trazem quebra de linha e tabulação.
---@param msg any
---@return string
local function one_line(msg)
  return (tostring(msg):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- O que o `luaopen_*` devolveu serve de módulo?
---@param mod any
---@return deckle.NativeModule|nil
---@return string|nil err
local function check(mod)
  if type(mod) ~= "table" or type(mod.render) ~= "function" then
    return nil, "the module does not export `render`"
  end
  return mod
end

--- Carrega o módulo de um arquivo, sem passar pelo `package.cpath`.
---@param path string
---@return deckle.NativeModule|nil
---@return string|nil err
local function from_file(path)
  local loader, err = package.loadlib(path, ENTRY)
  if not loader then
    return nil, one_line(err)
  end
  local ok, mod = pcall(loader)
  if not ok then
    return nil, one_line(mod)
  end
  return check(mod)
end

--- O arquivo do módulo no runtimepath, só para o checkhealth mostrar. `nil` quando o módulo veio
--- de um `package.preload` ou `package.loaded` e não de um arquivo.
---@return string|nil
local function runtimepath_file()
  local ok, found = pcall(vim.api.nvim_get_runtime_file, "lua/" .. MODULE .. ".*", false)
  return ok and found[1] or nil
end

---@return deckle.NativeModule|nil
---@return string|nil err
local function from_runtimepath()
  local ok, mod = pcall(require, MODULE)
  if not ok then
    -- `module 'deckle_native' not found:` seguido de um `no file ...` por entrada do cpath.
    -- Ficar sem o arquivo é o caso comum e não precisa da lista inteira.
    if tostring(mod):find("module '" .. MODULE .. "' not found", 1, true) then
      return nil, "no lua/deckle_native.so on the runtimepath"
    end
    return nil, one_line(mod)
  end
  return check(mod)
end

---@return deckle.NativeModule|nil
---@return string|nil err
---@return string|nil path
local function from_install()
  local ok, info = pcall(function()
    return require("deckle.install").info()
  end)
  if not ok then
    return nil, "could not inspect the installed binary: " .. one_line(info)
  end
  if info.origin == "missing" or not info.path then
    return nil, info.reason or "not installed"
  end
  local mod, err = from_file(info.path)
  return mod, err, info.path
end

--- Percorre os degraus. Devolve o módulo e de onde veio, ou `nil` e o motivo.
---@return deckle.NativeModule|nil mod
---@return string source_or_reason
---@return string|nil path
local function load_module()
  local configured = native_options().path
  if configured then
    local mod, err = from_file(configured)
    if mod then
      return mod, "config", configured
    end
    return nil, ("native.path %s: %s"):format(configured, err)
  end

  local mod, err = from_runtimepath()
  if mod then
    return mod, "runtimepath", runtimepath_file()
  end
  local reasons = { err }

  local path
  mod, err, path = from_install()
  if mod then
    return mod, "install", path
  end
  reasons[#reasons + 1] = ("installed binary%s: %s"):format(path and (" " .. path) or "", err)

  return nil, table.concat(reasons, "; ")
end

--- O módulo nativo, ou `nil` se ele não está disponível (camada 0).
---
--- A primeira chamada com `native.enabled` ligado faz a carga; as seguintes devolvem o
--- resultado guardado, inclusive a falha. Ver "Regras" no topo.
---@return deckle.NativeModule|nil
function M.get()
  if not native_options().enabled then
    return nil
  end
  if not state.attempted then
    state.attempted = true
    local ok, mod, source, path = pcall(load_module)
    if not ok then
      -- `load_module` não deveria lançar; se lançar, é um bug nosso e vira camada 0 com motivo.
      state.reason = "internal error while loading: " .. one_line(mod)
    elseif mod then
      state.module, state.source, state.path = mod, source, path
      if type(mod.version) == "function" then
        local version_ok, version = pcall(mod.version)
        state.version = version_ok and type(version) == "string" and version or nil
      end
    else
      state.reason = source
    end
  end
  return state.module
end

--- Retrato do que `get()` encontrou. Só lê: **não** provoca a carga, então antes do primeiro
--- `get()` devolve `attempted = false`. O checkhealth chama `get()` antes.
---@return deckle.NativeStatus
function M.status()
  local enabled = native_options().enabled
  local loaded = enabled and state.module ~= nil
  local reason
  if not enabled then
    reason = "disabled by `native.enabled = false`"
  elseif not loaded then
    reason = state.reason
  end
  return {
    enabled = enabled,
    attempted = state.attempted,
    loaded = loaded,
    source = loaded and state.source or nil,
    path = loaded and state.path or nil,
    version = loaded and state.version or nil,
    reason = reason,
  }
end

--- Esquece o resultado guardado, para a próxima `get()` carregar de novo. **Só para teste**:
--- não descarrega o `.so` (o Lua não tem como) e o `require` devolve o mesmo módulo, que o
--- `package.loaded` ainda guarda.
function M.reset()
  state = fresh()
end

return M
