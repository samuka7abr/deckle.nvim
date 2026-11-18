-- Testes de `deckle.native` (fase 7): o carregador do módulo nativo.
--
-- Nenhum caso exige o `.so` de verdade: o módulo é trocado por um stub (em `package.loaded`,
-- `package.preload` ou `package.loadlib`), então a suíte roda igual com ou sem `make native`.
-- O que prova o `.so` real está em `tests/native/test_mermaid_native.lua`.
--
-- Cada caso roda num Neovim filho: o estado do carregador é de módulo, e "nunca tenta de novo
-- na mesma sessão" só se prova com a sessão limpa.
--
-- O caminho de degradação (sem módulo, `native.path` quebrado, `native.enabled = false`) é
-- forçado, não comentado (ADR-0004).

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
      child.lua([==[
        -- Isola o filho de um `make native` na máquina de quem roda: o `require` não acha
        -- `lua/deckle_native.so` (o Neovim refaz o `package.cpath` a partir do runtimepath, então
        -- esvaziá-lo não adianta) a menos que o caso ponha um stub em `package.loaded` ou
        -- `package.preload`. O instalador (degrau 3) também é um stub.
        local real_require = require
        _G.require = function(name)
          if name == "deckle_native" and not package.loaded[name] and not package.preload[name] then
            error("module 'deckle_native' not found:\n\tno file (hidden by the test)", 0)
          end
          return real_require(name)
        end
        _G.install_info = { origin = "missing", reason = "not installed" }
        package.loaded["deckle.install"] = {
          info = function()
            return _G.install_info
          end,
        }

        _G.native = require("deckle.native")

        -- Módulo falso com a forma do `deckle_native`.
        _G.stub = function(version)
          return {
            render = function()
              return { "x" }
            end,
            supported_types = function()
              return { "flowchart", "sequence" }
            end,
            version = function()
              return version or "9.9.9"
            end,
          }
        end

        -- `package.loadlib` falso: registra as chamadas e devolve um carregador do stub.
        _G.loadlib_calls = {}
        _G.fake_loadlib = function(module)
          package.loadlib = function(path, entry)
            table.insert(_G.loadlib_calls, { path = path, entry = entry })
            return function()
              return module
            end
          end
        end

        _G.write_file = function(path, content)
          local fd = assert(io.open(path, "wb"))
          fd:write(content)
          fd:close()
        end
      ]==])
    end,
    post_once = child.stop,
  },
})

---@return table
local function status()
  return child.lua_get("_G.native.status()")
end

-- ---------------------------------------------------------------------------------------
-- Sem módulo: camada 0
-- ---------------------------------------------------------------------------------------

T["sem módulo"] = new_set()

T["sem módulo"]["get() devolve nil, não lança, e guarda o motivo de cada degrau"] = function()
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  local s = status()
  eq(s.attempted, true)
  eq(s.loaded, false)
  eq(s.enabled, true)
  eq(s.source, nil)
  -- O motivo cita os degraus que não deram: o runtimepath e o binário instalado.
  eq(s.reason:find("runtimepath", 1, true) ~= nil, true)
  eq(s.reason:find("installed binary: not installed", 1, true) ~= nil, true)
  -- Uma linha só: vai para o checkhealth.
  eq(s.reason:find("\n", 1, true), nil)
end

T["sem módulo"]["antes do primeiro get(), status() não carrega nada"] = function()
  child.lua(
    [[_G.native_tried = false; package.preload.deckle_native = function() _G.native_tried = true; return _G.stub() end]]
  )
  local s = status()
  eq(s.attempted, false)
  eq(s.loaded, false)
  eq(child.lua_get("_G.native_tried"), false)
end

T["sem módulo"]["native.enabled = false: nil na hora, sem tentar carregar"] = function()
  child.lua([[
    _G.loads = 0
    package.preload.deckle_native = function() _G.loads = _G.loads + 1; return _G.stub() end
    require("deckle.config").setup({ native = { enabled = false } })
  ]])
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  local s = status()
  eq(s.enabled, false)
  eq(s.loaded, false)
  eq(s.attempted, false)
  eq(s.reason:find("native.enabled = false", 1, true) ~= nil, true)
  eq(child.lua_get("_G.loads"), 0)
end

T["sem módulo"]["native.enabled é lido a cada chamada: desligar vale na hora, religar carrega"] = function()
  child.lua([[package.preload.deckle_native = function() return _G.stub() end]])
  eq(child.lua_get("_G.native.get() ~= nil"), true)

  child.lua([[require("deckle.config").setup({ native = { enabled = false } })]])
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  eq(status().loaded, false)

  child.lua([[require("deckle.config").setup({ native = { enabled = true } })]])
  eq(child.lua_get("_G.native.get() ~= nil"), true)
  eq(status().loaded, true)
end

T["sem módulo"]["native.path inexistente: nil, com o caminho e o motivo do dlopen"] = function()
  child.lua(
    [[require("deckle.config").setup({ native = { path = "/nonexistent/deckle_native.so" } })]]
  )
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  local s = status()
  eq(s.loaded, false)
  eq(s.reason:find("/nonexistent/deckle_native.so", 1, true) ~= nil, true)
  eq(s.reason:find("native.path", 1, true) ~= nil, true)
end

T["sem módulo"]["native.path quebrado não cai para o degrau seguinte (caminho explícito manda)"] = function()
  -- Há um módulo no runtimepath e um binário instalado. Mesmo assim, quem apontou um arquivo
  -- que não carrega fica na camada 0, com o motivo: carregar outro esconderia o erro.
  child.lua([[
    package.loaded.deckle_native = _G.stub()
    _G.install_info = { origin = "release", path = "/somewhere/deckle_native.so" }
    require("deckle.config").setup({ native = { path = "/nonexistent/deckle_native.so" } })
  ]])
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  eq(status().loaded, false)
end

T["sem módulo"]["native.path que não é um módulo (arquivo de texto) vira motivo, não erro"] = function()
  child.lua([[
    _G.bogus = vim.fn.tempname() .. ".so"
    _G.write_file(_G.bogus, "this is not an ELF file")
    require("deckle.config").setup({ native = { path = _G.bogus } })
  ]])
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  local s = status()
  eq(s.loaded, false)
  eq(s.reason:find(child.lua_get("_G.bogus"), 1, true) ~= nil, true)
  eq(s.reason:find("\n", 1, true), nil)
end

T["sem módulo"]["binário instalado que não carrega: o motivo cita o caminho"] = function()
  child.lua([[
    _G.bogus = vim.fn.tempname() .. ".so"
    _G.write_file(_G.bogus, "this is not an ELF file")
    _G.install_info = { origin = "release", path = _G.bogus }
  ]])
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  local reason = status().reason
  eq(reason:find("installed binary " .. child.lua_get("_G.bogus"), 1, true) ~= nil, true)
end

T["sem módulo"]["binário de outra versão (info missing com motivo) vira o motivo"] = function()
  child.lua(
    [[_G.install_info = { origin = "missing", reason = "the installed binary is for v0.0.1, this plugin is v9" }]]
  )
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  eq(status().reason:find("is for v0.0.1", 1, true) ~= nil, true)
end

T["sem módulo"]["o instalador lançando erro não derruba o carregador"] = function()
  child.lua([[package.loaded["deckle.install"] = { info = function() error("boom") end }]])
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  eq(status().reason:find("boom", 1, true) ~= nil, true)
end

T["sem módulo"]["módulo sem `render` é recusado"] = function()
  child.lua([[package.loaded.deckle_native = { version = function() return "1" end }]])
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  eq(status().reason:find("does not export `render`", 1, true) ~= nil, true)
end

T["sem módulo"]["luaopen que lança erro vira motivo"] = function()
  child.lua([[
    package.loadlib = function()
      return function()
        error("luaopen exploded")
      end
    end
    require("deckle.config").setup({ native = { path = "/x/deckle_native.so" } })
  ]])
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  eq(status().reason:find("luaopen exploded", 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------------------
-- Carregando: a ordem dos degraus
-- ---------------------------------------------------------------------------------------

T["ordem de carga"] = new_set()

T["ordem de carga"]["runtimepath: require acha o módulo"] = function()
  child.lua([[package.preload.deckle_native = function() return _G.stub("1.2.3") end]])
  eq(child.lua_get("_G.native.get() ~= nil"), true)
  local s = status()
  eq(s.loaded, true)
  eq(s.attempted, true)
  eq(s.source, "runtimepath")
  eq(s.version, "1.2.3")
  eq(s.reason, nil)
end

T["ordem de carga"]["native.path vence o runtimepath e carrega por package.loadlib"] = function()
  child.lua([[
    package.preload.deckle_native = function() return _G.stub("from-runtimepath") end
    _G.fake_loadlib(_G.stub("from-config"))
    require("deckle.config").setup({ native = { path = "/opt/deckle_native.so" } })
  ]])
  eq(child.lua_get("_G.native.get() ~= nil"), true)
  local s = status()
  eq(s.source, "config")
  eq(s.version, "from-config")
  eq(s.path, "/opt/deckle_native.so")
  -- O símbolo de entrada é o que o mlua exporta.
  eq(
    child.lua_get("_G.loadlib_calls"),
    { { path = "/opt/deckle_native.so", entry = "luaopen_deckle_native" } }
  )
end

T["ordem de carga"]["runtimepath vence o binário instalado"] = function()
  child.lua([[
    package.preload.deckle_native = function() return _G.stub("from-runtimepath") end
    _G.fake_loadlib(_G.stub("from-install"))
    _G.install_info = { origin = "release", path = "/data/deckle/deckle_native.so" }
  ]])
  eq(child.lua_get("_G.native.get() ~= nil"), true)
  eq(status().source, "runtimepath")
  eq(child.lua_get("#_G.loadlib_calls"), 0)
end

T["ordem de carga"]["sem runtimepath, carrega o que install.info() aponta por package.loadlib"] = function()
  child.lua([[
    _G.fake_loadlib(_G.stub("from-install"))
    _G.install_info = { origin = "release", path = "/data/deckle/deckle_native.so" }
  ]])
  eq(child.lua_get("_G.native.get() ~= nil"), true)
  local s = status()
  eq(s.source, "install")
  eq(s.version, "from-install")
  eq(s.path, "/data/deckle/deckle_native.so")
  eq(
    child.lua_get("_G.loadlib_calls"),
    { { path = "/data/deckle/deckle_native.so", entry = "luaopen_deckle_native" } }
  )
end

-- ---------------------------------------------------------------------------------------
-- Uma tentativa por sessão
-- ---------------------------------------------------------------------------------------

T["uma tentativa por sessão"] = new_set()

T["uma tentativa por sessão"]["carregado, get() devolve sempre o mesmo módulo sem recarregar"] = function()
  child.lua([[
    _G.loads = 0
    package.preload.deckle_native = function() _G.loads = _G.loads + 1; return _G.stub() end
  ]])
  eq(
    child.lua_get(
      "(function() local a = _G.native.get(); return a == _G.native.get() and a == _G.native.get() end)()"
    ),
    true
  )
  eq(child.lua_get("_G.loads"), 1)
end

T["uma tentativa por sessão"]["falhou, não tenta de novo, nem quando o módulo aparece depois"] = function()
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  child.lua([[
    _G.loads = 0
    package.preload.deckle_native = function() _G.loads = _G.loads + 1; return _G.stub() end
    _G.fake_loadlib(_G.stub())
    _G.install_info = { origin = "release", path = "/data/deckle/deckle_native.so" }
  ]])
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  eq(child.lua_get("_G.loads"), 0)
  eq(child.lua_get("#_G.loadlib_calls"), 0)
  eq(status().loaded, false)
end

T["uma tentativa por sessão"]["reset() esquece o resultado, e só ele"] = function()
  eq(child.lua_get("_G.native.get()"), vim.NIL)
  child.lua([[package.preload.deckle_native = function() return _G.stub() end]])
  eq(child.lua_get("_G.native.get()"), vim.NIL)

  child.lua("_G.native.reset()")
  eq(status().attempted, false)
  eq(child.lua_get("_G.native.get() ~= nil"), true)
  eq(status().loaded, true)

  -- E reset() de um módulo carregado também devolve ao zero.
  child.lua("_G.native.reset()")
  eq(status().loaded, false)
  eq(status().attempted, false)
end

return T
