--- Leitura do cabeçalho de um PNG (fase 9): só as dimensões, sem decodificar nada.
---
--- O deckle não desenha pixel. Precisa saber o tamanho da imagem para reservar as linhas dela no
--- preview, e quem decodifica é o terminal. Um PNG começa pela assinatura de 8 bytes e pelo
--- chunk `IHDR`, que é sempre o primeiro: 4 bytes de tamanho (13), `IHDR`, largura e altura em
--- 4 bytes cada, big-endian. Tudo que não bate com isso (JPEG, GIF, SVG, arquivo truncado, um
--- texto chamado `a.png`) não é PNG para o deckle e vira texto alternativo.

local M = {}

local SIGNATURE = "\137PNG\r\n\26\n"

--- Maior lado aceito, em pixels. É limite de sanidade (o `IHDR` admite 2^31), contra um cabeçalho
--- forjado que levasse a conta de linhas a números absurdos.
M.MAX_SIDE = 65535

---@param s string
---@param at integer
---@return integer
local function be32(s, at)
  local a, b, c, d = s:byte(at, at + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

--- Dimensões de um PNG, lidas dos 24 primeiros bytes.
---@param path string
---@return integer|nil width, integer|string height_or_reason
function M.size(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil, "cannot open the file"
  end
  local head = fd:read(24)
  fd:close()

  if not head or #head < 24 then
    return nil, "file too short to be a PNG"
  end
  if head:sub(1, 8) ~= SIGNATURE then
    return nil, "not a PNG file"
  end
  if be32(head, 9) ~= 13 or head:sub(13, 16) ~= "IHDR" then
    return nil, "PNG without an IHDR chunk first"
  end
  local width, height = be32(head, 17), be32(head, 21)
  if width < 1 or height < 1 or width > M.MAX_SIDE or height > M.MAX_SIDE then
    return nil, ("PNG dimensions out of range (%dx%d)"):format(width, height)
  end
  return width, height
end

return M
