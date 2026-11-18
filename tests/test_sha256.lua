-- Testes de `deckle.sha256`.
--
-- O hash é o que decide se um binário baixado entra no editor, então a implementação em Lua
-- é provada de duas formas: contra os vetores publicados pelo NIST e contra o `sha256sum`
-- (ou `shasum`) da máquina, em bytes arbitrários com NUL e com o tamanho em cada borda de
-- bloco, que é onde implementação de SHA-256 costuma errar.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local sha256 = require("deckle.sha256")

local T = new_set()

T["vetores do NIST"] = new_set()

T["vetores do NIST"]["string vazia"] = function()
  eq(sha256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
end

T["vetores do NIST"]["abc"] = function()
  eq(sha256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
end

T["vetores do NIST"]["mensagem de dois blocos"] = function()
  eq(
    sha256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  )
end

T["vetores do NIST"]["um milhão de `a`"] = function()
  eq(
    sha256.hex(string.rep("a", 1000000)),
    "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
  )
end

---@param n integer
---@return string bytes determinísticos, com NUL e bytes altos
local function pseudo_random(n)
  local state = 12345
  local out = {}
  for i = 1, n do
    state = (state * 1103515245 + 12345) % 2147483648
    out[i] = string.char(math.floor(state / 65536) % 256)
  end
  return table.concat(out)
end

--- Hash do arquivo pela ferramenta do sistema, ou nil quando não há nenhuma.
---@param path string
---@return string|nil
local function system_hash(path)
  local cmd
  if vim.fn.executable("sha256sum") == 1 then
    cmd = { "sha256sum", path }
  elseif vim.fn.executable("shasum") == 1 then
    cmd = { "shasum", "-a", "256", path }
  else
    return nil
  end
  local res = vim.system(cmd, { text = true }):wait()
  return res.code == 0 and res.stdout:match("^(%x+)") or nil
end

T["confere com a ferramenta do sistema"] = function()
  local tmp = vim.fn.tempname()
  -- Bordas do padding: 55 cabe com o comprimento no mesmo bloco, 56 obriga um bloco extra.
  for _, size in ipairs({ 0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 128, 1000, 4096 }) do
    local data = pseudo_random(size)
    local fd = assert(io.open(tmp, "wb"))
    fd:write(data)
    fd:close()

    local expected = system_hash(tmp)
    if expected == nil then
      MiniTest.skip("nem sha256sum nem shasum no PATH")
    end
    eq({ size, sha256.hex(data) }, { size, expected })
  end
  os.remove(tmp)
end

-- O `vim.fn.sha256` responde E976 a uma string com NUL (medido no 0.11.5): é por isso que
-- este módulo existe.
T["aceita byte NUL"] = function()
  eq(#sha256.hex("a\0b\0c"), 64)
  eq(sha256.hex("\0") == sha256.hex(""), false)
end

T["file() lê em modo binário e devolve o mesmo hash"] = function()
  local tmp = vim.fn.tempname()
  local data = pseudo_random(5000) .. "\r\n\26"
  local fd = assert(io.open(tmp, "wb"))
  fd:write(data)
  fd:close()
  eq(sha256.file(tmp), sha256.hex(data))
  os.remove(tmp)
end

T["file() de arquivo inexistente devolve nil e o motivo"] = function()
  local hash, err = sha256.file(vim.fn.tempname() .. "/nao-existe")
  eq(hash, nil)
  eq(type(err), "string")
end

T["um binário de 10 MB não trava o instalador"] = function()
  local data = string.rep("0123456789abcdef", 640 * 1024)
  local started = vim.uv.hrtime()
  local hash = sha256.hex(data)
  local seconds = (vim.uv.hrtime() - started) / 1e9
  eq(#hash, 64)
  -- Medido em ~0.15 s no JIT; o limite é folgado para CI lenta, e só pega regressão de ordem
  -- de grandeza (por exemplo, o JIT desligado por um laço que ele não compila).
  eq(seconds < 15, true)
end

return T
