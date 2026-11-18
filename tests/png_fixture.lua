-- PNGs para os testes de imagem (fase 9). Carregado por `dofile`, também dentro do Neovim filho.
--
-- O deckle só lê o cabeçalho (`IHDR`), então `bytes` monta assinatura mais `IHDR` do tamanho
-- pedido, sem dados de imagem: é o que permite um arquivo "de 4000 x 3000" de 33 bytes. O
-- `REAL_1X1` é um PNG de verdade (CRCs conferidos), para o caso de o parser só funcionar com o
-- arquivo que o próprio teste fabricou.

local M = {}

M.REAL_1X1 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

---@param n integer
---@return string
local function be32(n)
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256
  )
end

--- Assinatura PNG + chunk IHDR de `w` x `h` (CRC zerado: ninguém o confere).
---@param w integer
---@param h integer
---@return string
function M.bytes(w, h)
  return "\137PNG\r\n\26\n"
    .. be32(13)
    .. "IHDR"
    .. be32(w)
    .. be32(h)
    .. "\8\6\0\0\0"
    .. "\0\0\0\0"
end

---@param path string
---@param data string
function M.write_raw(path, data)
  local fd = assert(io.open(path, "wb"))
  fd:write(data)
  fd:close()
end

---@param path string
---@param w integer
---@param h integer
function M.write(path, w, h)
  M.write_raw(path, M.bytes(w, h))
end

return M
