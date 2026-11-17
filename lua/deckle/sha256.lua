--- SHA-256 em Lua puro (LuaJIT, via a biblioteca `bit`).
---
--- Existe porque `vim.fn.sha256` não serve para binário: o Vimscript recebe a string Lua com
--- byte NUL como Blob e responde `E976: Using a Blob as a String` (medido no Neovim 0.11.5
--- com um `.so` de verdade). `sha256sum` é Linux, `shasum` é macOS e no Windows sobra o
--- `certutil`, cada um com formato de saída próprio. Uma implementação só, que roda igual em
--- qualquer plataforma, é mais fácil de provar do que três ferramentas que não dá para
--- exercitar numa máquina só.
---
--- O custo é medido no teste: o `.so` de ~10 MB leva poucos décimos de segundo no JIT.

local bit = require("bit")

local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, ror, tobit = bit.lshift, bit.rshift, bit.ror, bit.tobit
local byte, char, rep, sub = string.byte, string.char, string.rep, string.sub

local M = {}

-- stylua: ignore
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

---@param state integer[] oito palavras de 32 bits, alteradas no lugar
---@param data string
---@param offset integer índice 0-based do primeiro byte do bloco de 64 bytes
local function compress(state, data, offset)
  local w = {}
  for i = 0, 15 do
    local a, b, c, d = byte(data, offset + i * 4 + 1, offset + i * 4 + 4)
    w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
  end
  for i = 16, 63 do
    local w15, w2 = w[i - 15], w[i - 2]
    local s0 = bxor(ror(w15, 7), ror(w15, 18), rshift(w15, 3))
    local s1 = bxor(ror(w2, 17), ror(w2, 19), rshift(w2, 10))
    w[i] = tobit(w[i - 16] + s0 + w[i - 7] + s1)
  end

  local a, b, c, d, e, f, g, h =
    state[1], state[2], state[3], state[4], state[5], state[6], state[7], state[8]
  for i = 0, 63 do
    local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
    local ch = bxor(band(e, f), band(bnot(e), g))
    local t1 = h + s1 + ch + K[i + 1] + w[i]
    local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
    local maj = bxor(band(a, b), band(a, c), band(b, c))
    local t2 = s0 + maj
    h, g, f, e, d, c, b, a = g, f, e, tobit(d + t1), c, b, a, tobit(t1 + t2)
  end

  state[1] = tobit(state[1] + a)
  state[2] = tobit(state[2] + b)
  state[3] = tobit(state[3] + c)
  state[4] = tobit(state[4] + d)
  state[5] = tobit(state[5] + e)
  state[6] = tobit(state[6] + f)
  state[7] = tobit(state[7] + g)
  state[8] = tobit(state[8] + h)
end

--- Hash de uma string de bytes qualquer, NUL incluído.
---@param data string
---@return string hex minúsculo, 64 caracteres
function M.hex(data)
  local state = {
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  }

  local len = #data
  local full = len - (len % 64)
  for offset = 0, full - 64, 64 do
    compress(state, data, offset)
  end

  -- Cauda: o que sobrou, o byte 0x80, zeros até 56 mod 64 e o comprimento em bits (64 bits,
  -- big-endian). O comprimento cabe em duas palavras sem perder precisão até 2^50 bytes.
  local tail = sub(data, full + 1)
  local pad = (55 - len) % 64
  local bits_hi = math.floor(len / 0x20000000)
  local bits_lo = (len * 8) % 0x100000000
  tail = tail
    .. "\128"
    .. rep("\0", pad)
    .. char(
      band(rshift(bits_hi, 24), 0xff),
      band(rshift(bits_hi, 16), 0xff),
      band(rshift(bits_hi, 8), 0xff),
      band(bits_hi, 0xff),
      band(rshift(bits_lo, 24), 0xff),
      band(rshift(bits_lo, 16), 0xff),
      band(rshift(bits_lo, 8), 0xff),
      band(bits_lo, 0xff)
    )
  for offset = 0, #tail - 64, 64 do
    compress(state, tail, offset)
  end

  local out = {}
  for i = 1, 8 do
    out[i] = bit.tohex(state[i], 8)
  end
  return table.concat(out)
end

--- Hash do conteúdo de um arquivo, lido inteiro em modo binário.
---@param path string
---@return string|nil hex
---@return string|nil err
function M.file(path)
  local fd, open_err = io.open(path, "rb")
  if not fd then
    return nil, tostring(open_err)
  end
  local data = fd:read("*a")
  fd:close()
  if not data then
    return nil, "could not read " .. path
  end
  return M.hex(data)
end

return M
