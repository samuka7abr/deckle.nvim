--- Instalador do binário nativo (camada 1). Fase 8 do roadmap; ver docs/architecture.md, seção 9.
---
--- Três degraus, nesta ordem, e o plugin funciona em qualquer um deles:
---
---   1. baixa `deckle_native-<target>.<ext>` da release `v<versão>` do GitHub, confere o
---      SHA-256 publicado ao lado (`.sha256`) e instala;
---   2. se não há binário (404, sem rede, plataforma fora da matriz), roda
---      `cargo build --release` no próprio plugin e copia o resultado com o nome certo;
---   3. se as duas falham, fica na camada 0. Sem erro: um `vim.notify` discreto e o motivo
---      registrado para o `:checkhealth deckle`.
---
--- **Checksum errado é a exceção.** Não cai para o cargo: um binário que não bate com o hash
--- publicado é um evento de integridade, não "não havia binário". A instalação aborta, nada é
--- instalado e o plugin fica na camada 0.
---
--- **Onde o binário mora.** `stdpath("data")/deckle/`, não dentro do plugin. Três motivos:
--- o diretório do plugin é do gerenciador (`lazy clean`, reinstalação e Nix o apagam ou o
--- deixam somente-leitura); o binário não suja o worktree do plugin; e o binário é do usuário
--- e da versão, não do checkout. O preço é que atualizar o plugin não atualiza o binário, e
--- por isso `info()` compara a versão gravada com `deckle.version` e trata a diferença como
--- binário ausente, em vez de carregar um `.so` de outra versão. A exceção é o
--- `lua/deckle_native.<ext>` que o `make native` deixa dentro do plugin: quem o gerou à mão
--- quer o que acabou de compilar, então ele tem precedência.
---
--- **Como a fase 7 usa isto.** `info()` é a única pergunta que ela precisa fazer:
---
---   local info = require("deckle.install").info()
---   -- info.origin: "release" | "build" | "missing"
---   -- info.path:   caminho absoluto do módulo, ou nil quando "missing"
---   local loader = package.loadlib(info.path, "luaopen_deckle_native")
---
--- Carregar por `package.loadlib` (e não por `require`) evita mexer em `package.cpath`: no
--- macOS o arquivo se chama `deckle_native.so`, não `.dylib`, e no Windows `.dll`.

local sha256 = require("deckle.sha256")

local uv = vim.uv
local joinpath = vim.fs.joinpath

local M = {}

--- Repositório de onde as releases saem.
M.REPO = "samuka7abr/deckle.nvim"

--- Alvos que o `release.yml` publica, com a extensão do arquivo da release. A extensão é a que
--- o cargo gera (`.so`, `.dylib`, `.dll`), não a que o Lua procura: ver `module_name`.
---@type table<string, string>
local RELEASE_TARGETS = {
  ["x86_64-unknown-linux-gnu"] = "so",
  ["aarch64-unknown-linux-gnu"] = "so",
  ["x86_64-apple-darwin"] = "dylib",
  ["aarch64-apple-darwin"] = "dylib",
  ["x86_64-pc-windows-msvc"] = "dll",
  ["aarch64-pc-windows-msvc"] = "dll",
}

local META_FILE = "install.json"

--- `jit.arch` e `uname -m` usam nomes diferentes para a mesma coisa.
local ARCH = {
  x64 = "x86_64",
  x86_64 = "x86_64",
  amd64 = "x86_64",
  AMD64 = "x86_64",
  arm64 = "aarch64",
  aarch64 = "aarch64",
  ARM64 = "aarch64",
}

local OS_PART = {
  Linux = "unknown-linux-gnu",
  Darwin = "apple-darwin",
  Windows_NT = "pc-windows-msvc",
}

--- Verdadeiro enquanto há uma instalação em andamento.
local running = false

-- ---------------------------------------------------------------------------------------
-- Plataforma
-- ---------------------------------------------------------------------------------------

---@class deckle.HostEnv
---@field sysname string "Linux" | "Darwin" | "Windows_NT"
---@field arch string "x64", "arm64", "x86_64", "aarch64"...
---@field musl boolean|nil

---@return deckle.HostEnv
local function host_env()
  local uname = uv.os_uname()
  -- `jit.arch` é a arquitetura do PROCESSO, que é o que o dlopen exige. `uname -m` pode
  -- dizer outra coisa (um Neovim x86_64 sob Rosetta num Mac arm64, por exemplo).
  local arch = jit and jit.arch or uname.machine
  local musl = false
  if uname.sysname == "Linux" then
    local loader = ("/lib/ld-musl-%s.so.1"):format(ARCH[arch] or "x86_64")
    musl = uv.fs_stat(loader) ~= nil
  end
  return { sysname = uname.sysname, arch = arch, musl = musl }
end

--- Triple da plataforma, no vocabulário do rustc. Não diz se existe release para ele.
---@param env deckle.HostEnv|nil padrão: a máquina atual
---@return string|nil triple
---@return string|nil err
function M.target(env)
  env = env or host_env()
  local arch = ARCH[env.arch]
  if not arch then
    return nil, ("unsupported architecture `%s`"):format(tostring(env.arch))
  end
  local os_part = OS_PART[env.sysname]
  if not os_part then
    return nil, ("unsupported system `%s`"):format(tostring(env.sysname))
  end
  -- Não há release para musl (Alpine): o `.so` de glibc não carrega lá. Devolver o triple
  -- real, e não glibc, faz o instalador pular o download e ir para o cargo.
  if env.sysname == "Linux" and env.musl then
    os_part = "unknown-linux-musl"
  end
  return arch .. "-" .. os_part
end

---@return string[] triples com binário na release, em ordem estável
function M.release_targets()
  local list = vim.tbl_keys(RELEASE_TARGETS)
  table.sort(list)
  return list
end

--- Nome do arquivo na release. É o que o `release.yml` publica.
---@param triple string
---@return string|nil nil quando não há release para o triple
function M.asset_name(triple)
  local ext = RELEASE_TARGETS[triple]
  if not ext then
    return nil
  end
  return ("deckle_native-%s.%s"):format(triple, ext)
end

--- Nome com que o módulo é instalado: sem o prefixo `lib` do cargo e com a extensão que o
--- `package.cpath` do LuaJIT usa, que no macOS é `.so` e não `.dylib`.
---@param sysname string|nil
---@return string
function M.module_name(sysname)
  sysname = sysname or uv.os_uname().sysname
  return sysname == "Windows_NT" and "deckle_native.dll" or "deckle_native.so"
end

--- Nome do arquivo que `cargo build` gera. A pegadinha do prefixo `lib` mora aqui: o cargo
--- gera `libdeckle_native.so`, o `require` só acha `deckle_native.so`.
---@param sysname string|nil
---@return string
function M.built_library(sysname)
  sysname = sysname or uv.os_uname().sysname
  if sysname == "Windows_NT" then
    return "deckle_native.dll"
  elseif sysname == "Darwin" then
    return "libdeckle_native.dylib"
  end
  return "libdeckle_native.so"
end

-- ---------------------------------------------------------------------------------------
-- Caminhos e metadados
-- ---------------------------------------------------------------------------------------

---@return string
local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(vim.fn.resolve(source), ":p:h:h:h")
end

--- Diretório onde o binário baixado ou compilado é instalado.
---@return string
function M.dir()
  return joinpath(vim.fn.stdpath("data"), "deckle")
end

---@class deckle.InstallOpts
---@field dir string|nil diretório de instalação (padrão: `M.dir()`)
---@field root string|nil raiz do plugin, onde o cargo roda (padrão: a deste arquivo)
---@field version string|nil versão do plugin (padrão: `deckle.version`)
---@field base_url string|nil prefixo das URLs dos arquivos (padrão: a release no GitHub)
---@field env deckle.HostEnv|nil plataforma a simular
---@field fetch fun(url: string, dest: string, cb: fun(err: string|nil))|nil baixa `url` para `dest`
---@field build fun(root: string, cb: fun(err: string|nil, artifact: string|nil))|nil compila e devolve o caminho do `libdeckle_native.*`
---@field silent boolean|nil não chama `vim.notify`

---@class deckle.Context
---@field dir string
---@field root string
---@field version string
---@field env deckle.HostEnv
---@field target string|nil
---@field target_err string|nil
---@field base_url string
---@field fetch fun(url: string, dest: string, cb: fun(err: string|nil))
---@field build fun(root: string, cb: fun(err: string|nil, artifact: string|nil))
---@field silent boolean

---@param opts deckle.InstallOpts|nil
---@return deckle.Context
local function context(opts)
  opts = opts or {}
  local version = opts.version or require("deckle.version")
  local env = opts.env or host_env()
  local target, target_err = M.target(env)
  return {
    dir = opts.dir or M.dir(),
    root = opts.root or plugin_root(),
    version = version,
    env = env,
    target = target,
    target_err = target_err,
    base_url = opts.base_url
      or ("https://github.com/%s/releases/download/v%s"):format(M.REPO, version),
    fetch = opts.fetch or M.curl_fetch,
    build = opts.build or function(root, cb)
      M.cargo_build(root, env, cb)
    end,
    silent = opts.silent == true,
  }
end

---@param dir string
---@return table|nil
local function read_meta(dir)
  local fd = io.open(joinpath(dir, META_FILE), "r")
  if not fd then
    return nil
  end
  local raw = fd:read("*a")
  fd:close()
  local ok, meta = pcall(vim.json.decode, raw)
  if ok and type(meta) == "table" then
    return meta
  end
  return nil
end

--- Grava por arquivo temporário e `rename`: quem lê nunca vê um arquivo pela metade.
---@param path string
---@param content string
---@return boolean ok
---@return string|nil err
local function write_atomic(path, content)
  local tmp = ("%s.tmp%d"):format(path, uv.os_getpid())
  local fd, open_err = io.open(tmp, "wb")
  if not fd then
    return false, tostring(open_err)
  end
  fd:write(content)
  fd:close()
  local ok, rename_err = uv.fs_rename(tmp, path)
  if not ok then
    uv.fs_unlink(tmp)
    return false, tostring(rename_err)
  end
  return true
end

---@param dir string
---@param meta table
---@return boolean ok
---@return string|nil err
local function write_meta(dir, meta)
  return write_atomic(joinpath(dir, META_FILE), vim.json.encode(meta))
end

-- ---------------------------------------------------------------------------------------
-- info(): a pergunta que a fase 7 e o checkhealth fazem
-- ---------------------------------------------------------------------------------------

---@class deckle.InstallInfo
---@field origin "release"|"build"|"missing" de onde veio o binário que vai ser carregado
---@field path string|nil caminho absoluto do módulo; nil quando `origin == "missing"`
---@field version string|nil versão do plugin para a qual o binário foi instalado
---@field target string|nil triple do binário
---@field source string|nil URL (release) ou como foi gerado (build)
---@field reason string|nil quando "missing": por que não há binário utilizável
---@field last_error string|nil mensagem da última instalação que falhou, se houve

--- Onde está o binário instalado e de onde veio. Lê só o disco, nunca a rede, e nunca lança.
---
--- Ordem de busca: `lua/deckle_native.<ext>` no plugin (`make native`), depois o diretório de
--- dados com metadados cuja versão bate com a do plugin. Um binário de outra versão não é
--- devolvido: a fase 7 não deve carregar um `.so` com contrato diferente.
---@param opts deckle.InstallOpts|nil
---@return deckle.InstallInfo
function M.info(opts)
  local ctx = context(opts)
  local filename = M.module_name(ctx.env.sysname)
  local meta = read_meta(ctx.dir)
  local last_error = meta and type(meta.last_error) == "table" and meta.last_error.message or nil

  local dev = joinpath(ctx.root, "lua", filename)
  if uv.fs_stat(dev) then
    return {
      origin = "build",
      path = dev,
      source = "make native",
      target = ctx.target,
      last_error = last_error,
    }
  end

  local reason = "not installed"
  local installed = joinpath(ctx.dir, filename)
  if meta and meta.origin ~= "missing" and uv.fs_stat(installed) then
    if meta.version == ctx.version then
      return {
        origin = meta.origin == "build" and "build" or "release",
        path = installed,
        version = meta.version,
        target = meta.target,
        source = meta.source,
        last_error = last_error,
      }
    end
    reason = ("the installed binary is for v%s, this plugin is v%s"):format(
      tostring(meta.version),
      ctx.version
    )
  end

  return { origin = "missing", reason = reason, last_error = last_error, target = ctx.target }
end

-- ---------------------------------------------------------------------------------------
-- Primitivas substituíveis (testes injetam as suas)
-- ---------------------------------------------------------------------------------------

--- Baixa `url` para `dest` com `curl`, sem bloquear o editor. Falha em HTTP >= 400 (`--fail`),
--- então um 404 de release inexistente vira erro, não um arquivo HTML de erro no lugar do
--- binário. Redirecionamento só para https. Aceita `file://`, que é como os testes servem
--- arquivos locais sem rede.
---@param url string
---@param dest string
---@param cb fun(err: string|nil)
function M.curl_fetch(url, dest, cb)
  if vim.fn.executable("curl") == 0 then
    return cb("curl not found in PATH")
  end
  local ok, spawn_err = pcall(vim.system, {
    "curl",
    "--fail",
    "--silent",
    "--show-error",
    "--location",
    "--proto-redir",
    "=https",
    "--connect-timeout",
    "10",
    "--max-time",
    "300",
    "--output",
    dest,
    url,
  }, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        cb(nil)
      else
        local detail = vim.trim(res.stderr or "")
        cb(("curl exit %d%s"):format(res.code, detail ~= "" and (": " .. detail) or ""))
      end
    end)
  end)
  if not ok then
    cb("could not run curl: " .. tostring(spawn_err))
  end
end

---@param text string|nil
---@return string
local function tail_of(text)
  local lines = vim.split(vim.trim(text or ""), "\n", { plain = true })
  return table.concat(vim.list_slice(lines, math.max(1, #lines - 3)), " | ")
end

--- `cargo build --release` no plugin. `--locked` usa o `Cargo.lock` versionado, que é o que
--- impede o merman de resolver para outra versão sem aviso (V5). `--target-dir` explícito
--- ignora `CARGO_TARGET_DIR` do usuário e deixa o caminho do artefato previsível.
---@param root string
---@param env deckle.HostEnv
---@param cb fun(err: string|nil, artifact: string|nil)
function M.cargo_build(root, env, cb)
  if vim.fn.executable("cargo") == 0 then
    return cb("cargo not found in PATH")
  end
  if not uv.fs_stat(joinpath(root, "Cargo.toml")) then
    return cb("Cargo.toml not found in " .. root)
  end
  local target_dir = joinpath(root, "target")
  local ok, spawn_err = pcall(vim.system, {
    "cargo",
    "build",
    "--release",
    "--locked",
    "-p",
    "deckle-native",
    "--target-dir",
    target_dir,
  }, { cwd = root, text = true, timeout = 20 * 60 * 1000 }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        return cb(("cargo build failed (exit %d): %s"):format(res.code, tail_of(res.stderr)))
      end
      cb(nil, joinpath(target_dir, "release", M.built_library(env.sysname)))
    end)
  end)
  if not ok then
    cb("could not run cargo: " .. tostring(spawn_err))
  end
end

-- ---------------------------------------------------------------------------------------
-- install()
-- ---------------------------------------------------------------------------------------

---@class deckle.InstallResult
---@field ok boolean
---@field stage string|nil onde falhou: "dir", "download", "checksum", "build", "install", "busy", "internal"
---@field error string|nil
---@field info deckle.InstallInfo estado depois da tentativa

--- Primeiro token hexadecimal de 64 caracteres do arquivo `.sha256`. Aceita só o hash e o
--- formato do `sha256sum` (`<hash>  <arquivo>`).
---@param path string
---@return string|nil
local function read_expected_hash(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local raw = fd:read("*a")
  fd:close()
  local token = raw:match("^%s*(%x+)")
  if token and #token == 64 then
    return token:lower()
  end
  return nil
end

--- Põe o arquivo verificado no lugar do módulo e grava os metadados.
---@param ctx deckle.Context
---@param tmp string arquivo já completo, no mesmo diretório do destino
---@param meta table
---@return boolean ok
---@return string|nil err
local function publish(ctx, tmp, meta)
  local final = joinpath(ctx.dir, M.module_name(ctx.env.sysname))
  -- `rename` por cima do arquivo antigo, nunca escrever nele: um `.so` truncado enquanto
  -- está mapeado por um Neovim em execução derruba o processo. Com `rename` o processo velho
  -- continua com o inode antigo. No Windows o `rename` falha se a DLL está carregada, e o
  -- erro diz o que fazer.
  local ok, err = uv.fs_rename(tmp, final)
  if not ok then
    uv.fs_unlink(tmp)
    return false,
      ("could not replace %s (%s); close other Neovim instances and retry"):format(
        final,
        tostring(err)
      )
  end
  local meta_ok, meta_err = write_meta(ctx.dir, meta)
  if not meta_ok then
    return false, "could not write install metadata: " .. tostring(meta_err)
  end
  return true
end

--- Degrau 1. `done(kind, err)`, com `kind` em "installed" | "unavailable" | "corrupt" |
--- "failed". `guarded` embrulha cada callback assíncrono (ver `M.install`).
---@param ctx deckle.Context
---@param done fun(kind: string, err: string|nil)
---@param guarded fun(fn: function): function
local function install_release(ctx, done, guarded)
  local asset = ctx.target and M.asset_name(ctx.target)
  if not asset then
    return done("unavailable", ctx.target_err or ("no release binary for " .. tostring(ctx.target)))
  end

  local url = ctx.base_url .. "/" .. asset
  local pid = uv.os_getpid()
  local tmp_bin = joinpath(ctx.dir, (".download-%d-%s"):format(pid, asset))
  local tmp_sum = tmp_bin .. ".sha256"

  local function cleanup()
    uv.fs_unlink(tmp_bin)
    uv.fs_unlink(tmp_sum)
  end

  ctx.fetch(
    url .. ".sha256",
    tmp_sum,
    guarded(function(sum_err)
      if sum_err then
        cleanup()
        return done("unavailable", ("%s: %s"):format(asset .. ".sha256", sum_err))
      end
      local expected = read_expected_hash(tmp_sum)
      if not expected then
        cleanup()
        return done("corrupt", ("%s.sha256 does not contain a SHA-256 hash"):format(asset))
      end

      ctx.fetch(
        url,
        tmp_bin,
        guarded(function(bin_err)
          if bin_err then
            cleanup()
            return done("unavailable", ("%s: %s"):format(asset, bin_err))
          end

          local actual, hash_err = sha256.file(tmp_bin)
          if not actual then
            cleanup()
            return done("corrupt", "could not hash the download: " .. tostring(hash_err))
          end
          if actual ~= expected then
            cleanup()
            return done(
              "corrupt",
              ("checksum mismatch for %s: expected %s, got %s"):format(asset, expected, actual)
            )
          end

          uv.fs_unlink(tmp_sum)
          local ok, err = publish(ctx, tmp_bin, {
            origin = "release",
            version = ctx.version,
            target = ctx.target,
            source = url,
            sha256 = actual,
            installed_at = os.time(),
          })
          if not ok then
            return done("failed", err)
          end
          done("installed")
        end)
      )
    end)
  )
end

--- Degrau 2. `done(ok, err)`.
---@param ctx deckle.Context
---@param done fun(ok: boolean, err: string|nil)
---@param guarded fun(fn: function): function
local function install_build(ctx, done, guarded)
  ctx.build(
    ctx.root,
    guarded(function(err, artifact)
      if err then
        return done(false, err)
      end
      if not artifact or not uv.fs_stat(artifact) then
        return done(false, "cargo build did not produce " .. tostring(artifact))
      end

      -- O arquivo instalado tem o nome do módulo, sem o prefixo `lib` do cargo.
      local module = M.module_name(ctx.env.sysname)
      local tmp = joinpath(ctx.dir, (".build-%d-%s"):format(uv.os_getpid(), module))
      local copied, copy_err = uv.fs_copyfile(artifact, tmp)
      if not copied then
        return done(false, ("could not copy %s: %s"):format(artifact, tostring(copy_err)))
      end

      local ok, publish_err = publish(ctx, tmp, {
        origin = "build",
        version = ctx.version,
        target = ctx.target or "unknown",
        source = "cargo build --release",
        installed_at = os.time(),
      })
      done(ok, publish_err)
    end)
  )
end

--- Guarda a falha no arquivo de metadados, sem apagar o que lá estava. É o que o
--- `:checkhealth deckle` mostra depois, já que a instalação não faz barulho.
---@param ctx deckle.Context
---@param message string
local function record_failure(ctx, message)
  local meta = read_meta(ctx.dir)
    or { origin = "missing", version = ctx.version, target = ctx.target }
  meta.last_error = { message = message, version = ctx.version, at = os.time() }
  pcall(write_meta, ctx.dir, meta)
end

---@param ctx deckle.Context
---@param result deckle.InstallResult
local function notify_result(ctx, result)
  if ctx.silent then
    return
  end
  if result.ok then
    local info = result.info
    local from = info.origin == "release" and "downloaded from the release" or "built locally"
    vim.notify(
      ("deckle: native binary %s (%s). Restart Neovim to load it."):format(from, info.path),
      vim.log.levels.INFO
    )
  else
    -- INFO, não ERROR: sem binário o plugin está na camada 0, que é um estado válido.
    vim.notify(
      ("deckle: no native binary, running on layer 0 (%s). See `:checkhealth deckle`."):format(
        result.error
      ),
      vim.log.levels.INFO
    )
  end
end

--- Instala o binário nativo. Assíncrono: devolve na hora e chama `callback` no fim, sempre
--- no loop principal e nunca com erro lançado. Falhar não é exceção, é a camada 0.
---
--- Para uso sem editor aberto (CI, Nix):
---   nvim --headless -c 'lua require("deckle.install").install(nil, function() vim.cmd("qa") end)'
---@param opts deckle.InstallOpts|nil
---@param callback fun(result: deckle.InstallResult)|nil
function M.install(opts, callback)
  local cb = callback or function() end
  local ctx = context(opts)

  if running then
    vim.schedule(function()
      cb({
        ok = false,
        stage = "busy",
        error = "another install is already running",
        info = M.info(opts),
      })
    end)
    return
  end
  running = true

  local finished = false
  ---@param ok boolean
  ---@param stage string|nil
  ---@param err string|nil
  local function finish(ok, stage, err)
    if finished then
      return
    end
    finished = true
    running = false
    if not ok then
      record_failure(ctx, err or "unknown error")
    end
    ---@type deckle.InstallResult
    local result = { ok = ok, stage = stage, error = err, info = M.info(opts) }
    notify_result(ctx, result)
    cb(result)
  end

  --- Uma exceção dentro de um callback assíncrono deixaria `running` preso para sempre.
  ---@generic T: function
  ---@param fn T
  ---@return T
  local function guarded(fn)
    return function(...)
      local ok, err = pcall(fn, ...)
      if not ok then
        finish(false, "internal", "internal error: " .. tostring(err))
      end
    end
  end

  pcall(vim.fn.mkdir, ctx.dir, "p")
  if vim.fn.isdirectory(ctx.dir) == 0 then
    return finish(false, "dir", "could not create " .. ctx.dir)
  end

  guarded(function()
    install_release(
      ctx,
      guarded(function(kind, release_err)
        if kind == "installed" then
          return finish(true)
        elseif kind == "corrupt" then
          -- Integridade: não tenta o cargo, aborta.
          return finish(false, "checksum", release_err)
        elseif kind == "failed" then
          -- Binário verificado, mas não deu para pô-lo no lugar. O cargo bateria no mesmo muro.
          return finish(false, "install", release_err)
        end

        if not ctx.silent then
          vim.notify(
            ("deckle: no prebuilt binary (%s); building with cargo, this can take a few minutes"):format(
              release_err
            ),
            vim.log.levels.INFO
          )
        end
        install_build(
          ctx,
          guarded(function(ok, build_err)
            if ok then
              return finish(true)
            end
            finish(false, "build", ("no release binary (%s); %s"):format(release_err, build_err))
          end),
          guarded
        )
      end),
      guarded
    )
  end)()
end

return M
