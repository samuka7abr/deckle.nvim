-- Testes de `deckle.install` (fase 8).
--
-- Nada aqui toca a rede nem o diretório de dados real: cada caso monta um sandbox em
-- `tempname()` com um "servidor" de arquivos local (`file://`, servido pelo `curl` de
-- verdade) e injeta o `build` no lugar do cargo. A plataforma também é injetada (`env`),
-- então o mesmo caso vale em Linux, macOS e Windows.
--
-- Os dois testes que o roadmap exige para a fase 8 estão marcados com "gate 2" e "gate 3":
-- checksum errado aborta a instalação e cai para a camada 0, e instalação sem rede termina
-- na camada 0 sem erro visível além do checkhealth.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local install = require("deckle.install")
local sha256 = require("deckle.sha256")

local LINUX = { sysname = "Linux", arch = "x64" }
local has_curl = vim.fn.executable("curl") == 1

local notes = {}
local original_notify

local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      notes = {}
      original_notify = vim.notify
      vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level or vim.log.levels.INFO }
      end
    end,
    post_case = function()
      vim.notify = original_notify
    end,
    post_once = function()
      child.stop()
    end,
  },
})

-- ---------------------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------------------

---@param path string
---@param content string
local function write(path, content)
  local fd = assert(io.open(path, "wb"))
  fd:write(content)
  fd:close()
end

---@param path string
---@return string|nil
local function read(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

---@param path string
---@return boolean
local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

---@return integer maior nível entre as notificações, ou 0 se não houve nenhuma
local function worst_level()
  local worst = 0
  for _, note in ipairs(notes) do
    worst = math.max(worst, note.level)
  end
  return worst
end

---@param env deckle.HostEnv|nil
---@return table
local function sandbox(env)
  env = env or LINUX
  local base = vim.fn.tempname()
  local box = {
    base = base,
    dir = base .. "/data/deckle",
    root = base .. "/plugin",
    served = base .. "/served",
    env = env,
    calls = { fetch = 0, build = 0 },
  }
  vim.fn.mkdir(box.root .. "/lua", "p")
  vim.fn.mkdir(box.served, "p")

  box.target = assert(install.target(env))
  box.asset = assert(install.asset_name(box.target))
  -- Bytes que não são texto: NUL e byte alto, como num `.so`.
  box.payload = "\127ELF\0\1\2fake deckle_native\0" .. string.rep("\0\255", 500)
  write(box.served .. "/" .. box.asset, box.payload)
  write(
    box.served .. "/" .. box.asset .. ".sha256",
    sha256.hex(box.payload) .. "  " .. box.asset .. "\n"
  )

  --- Opções do instalador apontando para o sandbox. `fetch` conta as chamadas e usa o
  --- `curl` de verdade; `build` falha, e cada caso troca por outro se precisar.
  function box.opts(extra)
    return vim.tbl_extend("force", {
      dir = box.dir,
      root = box.root,
      env = env,
      version = "9.9.9",
      base_url = "file://" .. box.served,
      fetch = function(url, dest, cb)
        box.calls.fetch = box.calls.fetch + 1
        install.curl_fetch(url, dest, cb)
      end,
      build = box.failing_build("cargo not found in PATH"),
    }, extra or {})
  end

  function box.failing_build(message)
    return function(_, cb)
      box.calls.build = box.calls.build + 1
      cb(message)
    end
  end

  --- Cargo de mentira: grava um `libdeckle_native.*` em `target/release` e devolve o caminho.
  function box.fake_build(content)
    return function(root, cb)
      box.calls.build = box.calls.build + 1
      local out = root .. "/target/release"
      vim.fn.mkdir(out, "p")
      local artifact = out .. "/" .. install.built_library(env.sysname)
      write(artifact, content)
      cb(nil, artifact)
    end
  end

  function box.installed_path()
    return box.dir .. "/" .. install.module_name(env.sysname)
  end

  return box
end

---@param opts table
---@return deckle.InstallResult
local function run(opts)
  local result
  install.install(opts, function(r)
    result = r
  end)
  vim.wait(20000, function()
    return result ~= nil
  end, 10)
  assert(result, "install() nunca chamou o callback")
  return result
end

--- Porta onde nada escuta: o `curl` recebe "connection refused" na hora, sem rede de verdade.
---@return integer
local function closed_port()
  local server = assert(vim.uv.new_tcp())
  assert(server:bind("127.0.0.1", 0))
  local port = server:getsockname().port
  server:close()
  return port
end

---@param dir string
---@return string[]
local function listing(dir)
  return vim.fn.readdir(dir)
end

-- ---------------------------------------------------------------------------------------
-- Plataforma e nomes
-- ---------------------------------------------------------------------------------------

T["plataforma"] = new_set()

T["plataforma"]["todo par sistema/arquitetura da matriz vira o triple do rustc"] = function()
  local cases = {
    { { sysname = "Linux", arch = "x64" }, "x86_64-unknown-linux-gnu" },
    { { sysname = "Linux", arch = "arm64" }, "aarch64-unknown-linux-gnu" },
    { { sysname = "Darwin", arch = "x64" }, "x86_64-apple-darwin" },
    { { sysname = "Darwin", arch = "arm64" }, "aarch64-apple-darwin" },
    { { sysname = "Windows_NT", arch = "x64" }, "x86_64-pc-windows-msvc" },
    { { sysname = "Windows_NT", arch = "arm64" }, "aarch64-pc-windows-msvc" },
  }
  for _, case in ipairs(cases) do
    eq(install.target(case[1]), case[2])
    eq(install.asset_name(case[2]) ~= nil, true)
  end
end

T["plataforma"]["aceita os nomes de `uname -m` além dos de `jit.arch`"] = function()
  eq(install.target({ sysname = "Linux", arch = "x86_64" }), "x86_64-unknown-linux-gnu")
  eq(install.target({ sysname = "Linux", arch = "aarch64" }), "aarch64-unknown-linux-gnu")
  eq(install.target({ sysname = "Windows_NT", arch = "AMD64" }), "x86_64-pc-windows-msvc")
  eq(install.target({ sysname = "Darwin", arch = "arm64" }), "aarch64-apple-darwin")
end

T["plataforma"]["arquitetura ou sistema desconhecido não vira triple"] = function()
  local triple, err = install.target({ sysname = "Linux", arch = "ppc" })
  eq(triple, nil)
  eq(err:match("unsupported architecture") ~= nil, true)

  triple, err = install.target({ sysname = "FreeBSD", arch = "x64" })
  eq(triple, nil)
  eq(err:match("unsupported system") ~= nil, true)
end

T["plataforma"]["musl não tem release: o triple real impede o download"] = function()
  local triple = install.target({ sysname = "Linux", arch = "x64", musl = true })
  eq(triple, "x86_64-unknown-linux-musl")
  eq(install.asset_name(triple), nil)
end

T["plataforma"]["nome do arquivo na release segue o alvo"] = function()
  eq(install.asset_name("x86_64-unknown-linux-gnu"), "deckle_native-x86_64-unknown-linux-gnu.so")
  eq(install.asset_name("aarch64-apple-darwin"), "deckle_native-aarch64-apple-darwin.dylib")
  eq(install.asset_name("x86_64-pc-windows-msvc"), "deckle_native-x86_64-pc-windows-msvc.dll")
end

T["plataforma"]["`release_targets()` é a matriz de 6 alvos"] = function()
  eq(#install.release_targets(), 6)
end

T["plataforma"]["o módulo instalado não tem o prefixo `lib` e usa a extensão do cpath"] = function()
  eq(install.module_name("Linux"), "deckle_native.so")
  -- No macOS o cargo gera `.dylib`, mas o `package.cpath` do LuaJIT procura `.so`.
  eq(install.module_name("Darwin"), "deckle_native.so")
  eq(install.module_name("Windows_NT"), "deckle_native.dll")
end

T["plataforma"]["o cargo gera o nome com `lib`, a pegadinha que o instalador desfaz"] = function()
  eq(install.built_library("Linux"), "libdeckle_native.so")
  eq(install.built_library("Darwin"), "libdeckle_native.dylib")
  eq(install.built_library("Windows_NT"), "deckle_native.dll")
end

T["plataforma"]["o diretório de instalação fica em stdpath('data')"] = function()
  eq(install.dir(), vim.fs.joinpath(vim.fn.stdpath("data"), "deckle"))
end

T["plataforma"]["a plataforma real tem triple e asset"] = function()
  local triple = install.target()
  eq(type(triple), "string")
end

-- ---------------------------------------------------------------------------------------
-- info()
-- ---------------------------------------------------------------------------------------

T["info"] = new_set()

T["info"]["sem nada instalado, diz que está ausente e por quê"] = function()
  local box = sandbox()
  local info = install.info(box.opts())
  eq(info.origin, "missing")
  eq(info.path, nil)
  eq(info.reason, "not installed")
end

T["info"]["não lança sem opções e devolve uma origem conhecida"] = function()
  local info = install.info()
  eq(vim.tbl_contains({ "release", "build", "missing" }, info.origin), true)
end

T["info"]["um `make native` dentro do plugin conta como build local e tem precedência"] = function()
  local box = sandbox()
  write(box.root .. "/lua/deckle_native.so", "dev")
  local info = install.info(box.opts())
  eq(info.origin, "build")
  eq(info.path, box.root .. "/lua/deckle_native.so")
end

T["info"]["binário de outra versão do plugin não é devolvido"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  eq(run(box.opts()).ok, true)

  local info = install.info(box.opts({ version = "10.0.0" }))
  eq(info.origin, "missing")
  eq(info.path, nil)
  eq(info.reason:match("v9%.9%.9") ~= nil, true)
  eq(info.reason:match("v10%.0%.0") ~= nil, true)
end

T["info"]["metadados sem o binário, ou o binário apagado, é ausente"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  eq(run(box.opts()).ok, true)
  os.remove(box.installed_path())
  eq(install.info(box.opts()).origin, "missing")
end

T["info"]["metadados corrompidos não lançam"] = function()
  local box = sandbox()
  vim.fn.mkdir(box.dir, "p")
  write(box.dir .. "/install.json", "{ isto não é json")
  write(box.installed_path(), "bin")
  eq(install.info(box.opts()).origin, "missing")
end

-- ---------------------------------------------------------------------------------------
-- Degrau 1: release
-- ---------------------------------------------------------------------------------------

T["release"] = new_set()

T["release"]["baixa, confere o checksum e instala com os metadados"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  local result = run(box.opts())

  eq(result.ok, true)
  eq(result.info.origin, "release")
  eq(result.info.path, box.installed_path())
  eq(result.info.version, "9.9.9")
  eq(result.info.target, "x86_64-unknown-linux-gnu")
  eq(read(box.installed_path()), box.payload)
  -- Só o binário e os metadados; nenhum temporário sobra.
  eq(listing(box.dir), { "deckle_native.so", "install.json" })

  local meta = vim.json.decode(read(box.dir .. "/install.json"))
  eq(meta.origin, "release")
  eq(meta.sha256, sha256.hex(box.payload))
  eq(meta.source, "file://" .. box.served .. "/" .. box.asset)
  eq(box.calls.build, 0)
end

T["release"]["avisa com INFO e diz para reiniciar"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  eq(run(box.opts()).ok, true)
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.INFO)
  eq(notes[1].msg:match("Restart Neovim") ~= nil, true)
end

T["release"]["`silent` não notifica"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  eq(run(box.opts({ silent = true })).ok, true)
  eq(#notes, 0)
end

T["release"]["aceita o `.sha256` só com o hash, em maiúsculas"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  write(box.served .. "/" .. box.asset .. ".sha256", sha256.hex(box.payload):upper() .. "\n")
  eq(run(box.opts()).ok, true)
end

T["release"]["macOS instala o `.dylib` da release como `deckle_native.so`"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox({ sysname = "Darwin", arch = "arm64" })
  eq(box.asset, "deckle_native-aarch64-apple-darwin.dylib")
  local result = run(box.opts())
  eq(result.ok, true)
  eq(result.info.path, box.dir .. "/deckle_native.so")
  eq(read(box.dir .. "/deckle_native.so"), box.payload)
end

T["release"]["Windows instala `deckle_native.dll`"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox({ sysname = "Windows_NT", arch = "x64" })
  local result = run(box.opts())
  eq(result.ok, true)
  eq(result.info.path, box.dir .. "/deckle_native.dll")
end

T["release"]["reinstalar troca o binário por rename, sem truncar o arquivo em uso"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  eq(run(box.opts()).ok, true)
  local before = vim.uv.fs_stat(box.installed_path()).ino

  local newer = box.payload .. "v2"
  write(box.served .. "/" .. box.asset, newer)
  write(box.served .. "/" .. box.asset .. ".sha256", sha256.hex(newer) .. "\n")
  eq(run(box.opts()).ok, true)

  eq(read(box.installed_path()), newer)
  -- Outro inode: o arquivo antigo, mapeado por um Neovim em execução, não foi reescrito.
  eq(vim.uv.fs_stat(box.installed_path()).ino ~= before, true)
end

-- ---------------------------------------------------------------------------------------
-- Gate 2: checksum errado
-- ---------------------------------------------------------------------------------------

T["gate 2: checksum errado"] = new_set()

---@param box table
---@param result deckle.InstallResult
local function expect_aborted_on_layer_0(box, result)
  eq(result.ok, false)
  eq(result.stage, "checksum")
  eq(result.error:match("checksum mismatch") ~= nil, true)
  -- Nada foi instalado, e o plugin cai para a camada 0.
  eq(exists(box.installed_path()), false)
  eq(result.info.origin, "missing")
  eq(result.info.path, nil)
  -- Aborta: não tenta o cargo.
  eq(box.calls.build, 0)
  -- Nem o binário rejeitado nem o `.sha256` ficam no disco.
  eq(vim.tbl_contains(listing(box.dir), "deckle_native.so"), false)
  for _, name in ipairs(listing(box.dir)) do
    eq(name:match("^%.download") == nil, true)
  end
end

T["gate 2: checksum errado"]["hash falso no `.sha256` aborta e cai para a camada 0"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  write(
    box.served .. "/" .. box.asset .. ".sha256",
    string.rep("a", 64) .. "  " .. box.asset .. "\n"
  )

  local result = run(box.opts())
  expect_aborted_on_layer_0(box, result)
  eq(result.error:match(string.rep("a", 64)) ~= nil, true)
end

T["gate 2: checksum errado"]["binário adulterado em um byte aborta"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  -- O `.sha256` é o do binário original; o que chega pela rede foi alterado.
  write(box.served .. "/" .. box.asset, box.payload .. "x")
  expect_aborted_on_layer_0(box, run(box.opts()))
end

T["gate 2: checksum errado"]["`.sha256` que não é um hash aborta"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  write(box.served .. "/" .. box.asset .. ".sha256", "<html>not found</html>\n")

  local result = run(box.opts())
  eq(result.ok, false)
  eq(result.stage, "checksum")
  eq(exists(box.installed_path()), false)
  eq(box.calls.build, 0)
end

T["gate 2: checksum errado"]["só avisa com INFO, sem erro visível"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  write(box.served .. "/" .. box.asset .. ".sha256", string.rep("0", 64) .. "\n")
  run(box.opts())
  eq(worst_level() <= vim.log.levels.INFO, true)
  eq(vim.v.errmsg, "")
end

T["gate 2: checksum errado"]["não derruba o binário bom que já estava instalado"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  eq(run(box.opts()).ok, true)

  write(box.served .. "/" .. box.asset .. ".sha256", string.rep("b", 64) .. "\n")
  local result = run(box.opts())
  eq(result.ok, false)
  eq(result.stage, "checksum")
  eq(read(box.installed_path()), box.payload)
  eq(result.info.origin, "release")
  eq(result.info.last_error:match("checksum mismatch") ~= nil, true)
end

T["gate 2: checksum errado"]["o motivo fica nos metadados para o checkhealth"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  write(box.served .. "/" .. box.asset .. ".sha256", string.rep("c", 64) .. "\n")
  local result = run(box.opts())
  eq(result.info.last_error:match("checksum mismatch") ~= nil, true)
  eq(install.info(box.opts()).last_error, result.info.last_error)
end

-- ---------------------------------------------------------------------------------------
-- Degrau 2: cargo
-- ---------------------------------------------------------------------------------------

T["cargo"] = new_set()

T["cargo"]["release inexistente cai para o cargo, e `lib*` vira `deckle_native.so`"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  local built = "\127ELF compiled locally \0\0"
  -- A release que não existe dá 404 no curl, que vira "sem binário", e o cargo assume.
  local result = run(box.opts({
    base_url = "file://" .. box.base .. "/nao-existe",
    build = box.fake_build(built),
  }))

  eq(result.ok, true)
  eq(box.calls.build, 1)
  eq(result.info.origin, "build")
  eq(result.info.path, box.dir .. "/deckle_native.so")
  eq(read(box.dir .. "/deckle_native.so"), built)
  eq(exists(box.dir .. "/libdeckle_native.so"), false)
  eq(listing(box.dir), { "deckle_native.so", "install.json" })
  eq(vim.json.decode(read(box.dir .. "/install.json")).origin, "build")
end

T["cargo"]["no macOS o `libdeckle_native.dylib` vira `deckle_native.so`"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox({ sysname = "Darwin", arch = "x64" })
  local result = run(box.opts({
    base_url = "file://" .. box.base .. "/nao-existe",
    build = box.fake_build("macho"),
  }))
  eq(result.ok, true)
  eq(read(box.dir .. "/deckle_native.so"), "macho")
  eq(exists(box.root .. "/target/release/libdeckle_native.dylib"), true)
end

T["cargo"]["avisa com INFO que vai compilar"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  run(box.opts({
    base_url = "file://" .. box.base .. "/nao-existe",
    build = box.fake_build("bin"),
  }))
  eq(notes[1].msg:match("building with cargo") ~= nil, true)
  eq(worst_level() <= vim.log.levels.INFO, true)
end

T["cargo"]["plataforma fora da matriz nem tenta baixar"] = function()
  local box = sandbox()
  local fetched = box.calls
  local result = run(box.opts({
    env = { sysname = "FreeBSD", arch = "x64" },
    build = box.fake_build("bin"),
  }))
  eq(fetched.fetch, 0)
  eq(fetched.build, 1)
  eq(result.ok, true)
  eq(result.info.origin, "build")
end

T["cargo"]["musl nem tenta baixar o binário de glibc"] = function()
  local box = sandbox()
  local result = run(box.opts({
    env = { sysname = "Linux", arch = "x64", musl = true },
    build = box.fake_build("bin"),
  }))
  eq(box.calls.fetch, 0)
  eq(result.ok, true)
  eq(result.info.target, "x86_64-unknown-linux-musl")
end

T["cargo"]["artefato que o cargo disse ter gerado e não existe é falha"] = function()
  local box = sandbox()
  local result = run(box.opts({
    env = { sysname = "FreeBSD", arch = "x64" },
    build = function(_, cb)
      cb(nil, box.root .. "/target/release/libdeckle_native.so")
    end,
  }))
  eq(result.ok, false)
  eq(result.stage, "build")
  eq(result.error:match("did not produce") ~= nil, true)
  eq(result.info.origin, "missing")
end

T["cargo"]["`cargo_build` sem cargo no PATH devolve erro legível"] = function()
  local original = vim.env.PATH
  vim.env.PATH = ""
  local err
  local ok, thrown = pcall(install.cargo_build, vim.fn.tempname(), LINUX, function(e)
    err = e
  end)
  vim.env.PATH = original
  eq(ok, true, thrown)
  eq(err, "cargo not found in PATH")
end

T["cargo"]["`cargo_build` fora de um checkout do plugin devolve erro legível"] = function()
  if vim.fn.executable("cargo") == 0 then
    MiniTest.skip("cargo ausente")
  end
  local empty = vim.fn.tempname()
  vim.fn.mkdir(empty, "p")
  local err
  install.cargo_build(empty, LINUX, function(e)
    err = e
  end)
  eq(err:match("Cargo.toml not found") ~= nil, true)
end

-- ---------------------------------------------------------------------------------------
-- Gate 3: sem rede
-- ---------------------------------------------------------------------------------------

T["gate 3: sem rede"] = new_set()

---@param box table
---@param result deckle.InstallResult
local function expect_layer_0_without_noise(box, result)
  eq(result.ok, false)
  eq(result.info.origin, "missing")
  eq(result.info.path, nil)
  eq(exists(box.installed_path()), false)
  -- O motivo vai para o checkhealth...
  eq(type(result.info.last_error), "string")
  -- ...e o que o usuário vê é no máximo uma linha de INFO, nunca WARN nem ERROR.
  eq(worst_level() <= vim.log.levels.INFO, true)
  eq(vim.v.errmsg, "")
end

T["gate 3: sem rede"]["curl de verdade contra uma porta fechada termina na camada 0"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  local box = sandbox()
  local result = run(box.opts({
    base_url = ("http://127.0.0.1:%d/deckle"):format(closed_port()),
    build = box.failing_build("cargo not found in PATH"),
  }))

  expect_layer_0_without_noise(box, result)
  eq(result.stage, "build")
  eq(result.error:match("curl exit 7") ~= nil, true)
  eq(result.error:match("cargo not found") ~= nil, true)
  eq(box.calls.build, 1)
end

T["gate 3: sem rede"]["downloader que falha com erro de rede termina na camada 0"] = function()
  local box = sandbox()
  local result = run(box.opts({
    fetch = function(_, _, cb)
      box.calls.fetch = box.calls.fetch + 1
      cb("curl exit 6: Could not resolve host: github.com")
    end,
  }))

  expect_layer_0_without_noise(box, result)
  eq(box.calls.fetch, 1)
  eq(result.error:match("Could not resolve host") ~= nil, true)
end

T["gate 3: sem rede"]["sem curl no PATH termina na camada 0"] = function()
  local box = sandbox()
  local original = vim.env.PATH
  vim.env.PATH = ""
  local ok, result = pcall(run, box.opts({ fetch = install.curl_fetch }))
  vim.env.PATH = original

  eq(ok, true, result)
  expect_layer_0_without_noise(box, result)
  eq(result.error:match("curl not found") ~= nil, true)
end

T["gate 3: sem rede"]["sem rede e com cargo funcionando, a build assume"] = function()
  local box = sandbox()
  local result = run(box.opts({
    fetch = function(_, _, cb)
      cb("curl exit 7: Failed to connect")
    end,
    build = box.fake_build("compiled"),
  }))
  eq(result.ok, true)
  eq(result.info.origin, "build")
end

T["gate 3: sem rede"]["diretório de instalação impossível de criar também é camada 0"] = function()
  local box = sandbox()
  -- O pai do diretório é um arquivo, então `mkdir -p` não tem como funcionar.
  local blocker = box.base .. "/blocker"
  write(blocker, "x")
  local result = run(box.opts({ dir = blocker .. "/deckle" }))
  eq(result.ok, false)
  eq(result.stage, "dir")
  eq(result.info.origin, "missing")
end

-- ---------------------------------------------------------------------------------------
-- Robustez
-- ---------------------------------------------------------------------------------------

T["robustez"] = new_set()

T["robustez"]["duas instalações ao mesmo tempo: a segunda é recusada"] = function()
  local box = sandbox()
  local pending
  local first
  install.install(
    box.opts({
      fetch = function(_, _, cb)
        pending = cb
      end,
    }),
    function(r)
      first = r
    end
  )
  eq(type(pending), "function")

  local second = run(box.opts())
  eq(second.ok, false)
  eq(second.stage, "busy")

  pending("curl exit 7: Failed to connect")
  vim.wait(5000, function()
    return first ~= nil
  end, 10)
  eq(first.ok, false)
end

T["robustez"]["exceção num callback vira falha, e a trava é liberada"] = function()
  local box = sandbox()
  local result = run(box.opts({
    fetch = function()
      error("boom")
    end,
  }))
  eq(result.ok, false)
  eq(result.stage, "internal")
  eq(result.error:match("boom") ~= nil, true)

  -- Se `running` tivesse ficado preso, esta chamada voltaria como "busy".
  local again = run(box.opts({
    build = box.fake_build("bin"),
    fetch = function(_, _, cb)
      cb("curl exit 7")
    end,
  }))
  eq(again.ok, true)
end

T["robustez"]["o callback é opcional"] = function()
  local box = sandbox()
  eq(
    pcall(
      install.install,
      box.opts({
        fetch = function(_, _, cb)
          cb("curl exit 7")
        end,
      })
    ),
    true
  )
  vim.wait(200)
  eq(worst_level() <= vim.log.levels.INFO, true)
end

-- ---------------------------------------------------------------------------------------
-- No editor de verdade (Neovim filho)
-- ---------------------------------------------------------------------------------------

T["no editor"] = new_set()

--- Um `make native` na própria máquina deixa `lua/deckle_native.*` no plugin, e o
--- checkhealth do filho (que usa a raiz real do plugin) passa a dizer "build local".
local function skip_with_dev_build()
  if vim.uv.fs_stat("lua/deckle_native.so") or vim.uv.fs_stat("lua/deckle_native.dll") then
    MiniTest.skip("há um `make native` neste checkout (lua/deckle_native.*)")
  end
end

T["no editor"]["`:Deckle install` chama o instalador"] = function()
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.lua([[
    _G.called = 0
    require("deckle.install").install = function()
      _G.called = _G.called + 1
    end
  ]])
  child.cmd("Deckle install")
  eq(child.lua_get("_G.called"), 1)
end

T["no editor"]["gate 3: sem rede, a instalação termina na camada 0 e o checkhealth explica"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  skip_with_dev_build()
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.lua(
    [[
      local port = ...
      vim.env.XDG_DATA_HOME = vim.fn.tempname()
      _G.notes = {}
      vim.notify = function(msg, level)
        table.insert(_G.notes, level)
      end
      _G.result = nil
      require("deckle.install").install({
        base_url = ("http://127.0.0.1:%d/deckle"):format(port),
        -- Sem cargo: a segunda saída também falha.
        build = function(_, cb)
          cb("cargo not found in PATH")
        end,
      }, function(result)
        _G.result = result
      end)
    ]],
    { closed_port() }
  )
  child.lua([[vim.wait(20000, function() return _G.result ~= nil end, 20)]])

  eq(child.lua_get("_G.result.ok"), false)
  eq(child.lua_get("_G.result.info.origin"), "missing")
  -- Nenhuma notificação acima de INFO.
  eq(child.lua_get("vim.tbl_filter(function(l) return l > vim.log.levels.INFO end, _G.notes)"), {})

  child.cmd("checkhealth deckle")
  local report = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  eq(report:match("Native binary") ~= nil, true)
  eq(report:match("missing") ~= nil, true)
  eq(report:match("last install attempt failed") ~= nil, true)
  eq(report:match("cargo not found") ~= nil, true)
  -- Camada 0 continua sendo o que o relatório diz: o plugin segue funcionando.
  eq(report:match("layer 0") ~= nil, true)
end

T["no editor"]["gate 2: checksum falso, no editor, termina na camada 0"] = function()
  if not has_curl then
    MiniTest.skip("curl ausente")
  end
  skip_with_dev_build()
  local box = sandbox()
  write(box.served .. "/" .. box.asset .. ".sha256", string.rep("d", 64) .. "\n")

  child.restart({ "-u", "tests/minimal_init.lua" })
  child.lua(
    [[
      local served, env = ...
      vim.env.XDG_DATA_HOME = vim.fn.tempname()
      _G.result = nil
      _G.build_calls = 0
      require("deckle.install").install({
        env = env,
        base_url = "file://" .. served,
        silent = true,
        build = function(_, cb)
          _G.build_calls = _G.build_calls + 1
          cb("must not be called")
        end,
      }, function(result)
        _G.result = result
      end)
    ]],
    { box.served, LINUX }
  )
  child.lua([[vim.wait(20000, function() return _G.result ~= nil end, 20)]])

  eq(child.lua_get("_G.result.ok"), false)
  eq(child.lua_get("_G.result.stage"), "checksum")
  eq(child.lua_get("_G.result.info.origin"), "missing")
  eq(child.lua_get("_G.build_calls"), 0)

  child.cmd("checkhealth deckle")
  local report = table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  eq(report:match("checksum mismatch") ~= nil, true)
end

return T
