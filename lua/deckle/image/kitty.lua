--- Bytes do protocolo gráfico do kitty (fase 9), puros: nenhuma função aqui toca no Neovim nem no
--- terminal. Quem escreve no tty é `deckle.image`; este módulo só monta o que ele escreve, e por
--- isso os testes comparam os bytes com o formato do protocolo.
---
--- Referência: https://sw.kovidgoyal.net/kitty/graphics-protocol/ (seções "Unicode placeholders"
--- e "Deleting images").
---
--- # Unicode placeholders
---
--- A imagem é transmitida uma vez (`a=t`) e ganha um posicionamento **virtual** (`a=p,U=1`) de
--- `c` colunas por `r` linhas. Ela só aparece onde o texto tiver o caractere `U+10EEEE`, com o id
--- da imagem na cor do primeiro plano (o id é a cor: `38;5;<id>` em 256 cores, `38;2;0;0;<id>` em
--- cor verdadeira, e por isso o id cabe em um byte) e dois diacríticos que dizem a linha e a coluna
--- daquela célula dentro da imagem. Como o placeholder é texto comum, o Neovim o move com o
--- buffer: rolar, redimensionar a janela e trocar de aba reposicionam a imagem sem uma linha de
--- código nossa. É a razão de a escolha ter sido esta, e não o posicionamento por coordenada.
---
--- Cada célula leva a linha e a coluna por extenso, mesmo que o protocolo deixe omitir as que
--- seguem o vizinho da esquerda: são mais bytes, e em troca não depende de o terminal adivinhar
--- certo quando o Neovim redesenha só um pedaço da linha.

local M = {}

--- Os diacríticos que numeram linha e coluna, na ordem do protocolo (o índice 1 é o número 0).
--- Copiados de `gen/rowcolumn-diacritics.txt` do kitty: 297 combinantes da classe 230.
---@type integer[]
M.DIACRITICS = {
  0x0305,
  0x030D,
  0x030E,
  0x0310,
  0x0312,
  0x033D,
  0x033E,
  0x033F,
  0x0346,
  0x034A,
  0x034B,
  0x034C,
  0x0350,
  0x0351,
  0x0352,
  0x0357,
  0x035B,
  0x0363,
  0x0364,
  0x0365,
  0x0366,
  0x0367,
  0x0368,
  0x0369,
  0x036A,
  0x036B,
  0x036C,
  0x036D,
  0x036E,
  0x036F,
  0x0483,
  0x0484,
  0x0485,
  0x0486,
  0x0487,
  0x0592,
  0x0593,
  0x0594,
  0x0595,
  0x0597,
  0x0598,
  0x0599,
  0x059C,
  0x059D,
  0x059E,
  0x059F,
  0x05A0,
  0x05A1,
  0x05A8,
  0x05A9,
  0x05AB,
  0x05AC,
  0x05AF,
  0x05C4,
  0x0610,
  0x0611,
  0x0612,
  0x0613,
  0x0614,
  0x0615,
  0x0616,
  0x0617,
  0x0657,
  0x0658,
  0x0659,
  0x065A,
  0x065B,
  0x065D,
  0x065E,
  0x06D6,
  0x06D7,
  0x06D8,
  0x06D9,
  0x06DA,
  0x06DB,
  0x06DC,
  0x06DF,
  0x06E0,
  0x06E1,
  0x06E2,
  0x06E4,
  0x06E7,
  0x06E8,
  0x06EB,
  0x06EC,
  0x0730,
  0x0732,
  0x0733,
  0x0735,
  0x0736,
  0x073A,
  0x073D,
  0x073F,
  0x0740,
  0x0741,
  0x0743,
  0x0745,
  0x0747,
  0x0749,
  0x074A,
  0x07EB,
  0x07EC,
  0x07ED,
  0x07EE,
  0x07EF,
  0x07F0,
  0x07F1,
  0x07F3,
  0x0816,
  0x0817,
  0x0818,
  0x0819,
  0x081B,
  0x081C,
  0x081D,
  0x081E,
  0x081F,
  0x0820,
  0x0821,
  0x0822,
  0x0823,
  0x0825,
  0x0826,
  0x0827,
  0x0829,
  0x082A,
  0x082B,
  0x082C,
  0x082D,
  0x0951,
  0x0953,
  0x0954,
  0x0F82,
  0x0F83,
  0x0F86,
  0x0F87,
  0x135D,
  0x135E,
  0x135F,
  0x17DD,
  0x193A,
  0x1A17,
  0x1A75,
  0x1A76,
  0x1A77,
  0x1A78,
  0x1A79,
  0x1A7A,
  0x1A7B,
  0x1A7C,
  0x1B6B,
  0x1B6D,
  0x1B6E,
  0x1B6F,
  0x1B70,
  0x1B71,
  0x1B72,
  0x1B73,
  0x1CD0,
  0x1CD1,
  0x1CD2,
  0x1CDA,
  0x1CDB,
  0x1CE0,
  0x1DC0,
  0x1DC1,
  0x1DC3,
  0x1DC4,
  0x1DC5,
  0x1DC6,
  0x1DC7,
  0x1DC8,
  0x1DC9,
  0x1DCB,
  0x1DCC,
  0x1DD1,
  0x1DD2,
  0x1DD3,
  0x1DD4,
  0x1DD5,
  0x1DD6,
  0x1DD7,
  0x1DD8,
  0x1DD9,
  0x1DDA,
  0x1DDB,
  0x1DDC,
  0x1DDD,
  0x1DDE,
  0x1DDF,
  0x1DE0,
  0x1DE1,
  0x1DE2,
  0x1DE3,
  0x1DE4,
  0x1DE5,
  0x1DE6,
  0x1DFE,
  0x20D0,
  0x20D1,
  0x20D4,
  0x20D5,
  0x20D6,
  0x20D7,
  0x20DB,
  0x20DC,
  0x20E1,
  0x20E7,
  0x20E9,
  0x20F0,
  0x2CEF,
  0x2CF0,
  0x2CF1,
  0x2DE0,
  0x2DE1,
  0x2DE2,
  0x2DE3,
  0x2DE4,
  0x2DE5,
  0x2DE6,
  0x2DE7,
  0x2DE8,
  0x2DE9,
  0x2DEA,
  0x2DEB,
  0x2DEC,
  0x2DED,
  0x2DEE,
  0x2DEF,
  0x2DF0,
  0x2DF1,
  0x2DF2,
  0x2DF3,
  0x2DF4,
  0x2DF5,
  0x2DF6,
  0x2DF7,
  0x2DF8,
  0x2DF9,
  0x2DFA,
  0x2DFB,
  0x2DFC,
  0x2DFD,
  0x2DFE,
  0x2DFF,
  0xA66F,
  0xA67C,
  0xA67D,
  0xA6F0,
  0xA6F1,
  0xA8E0,
  0xA8E1,
  0xA8E2,
  0xA8E3,
  0xA8E4,
  0xA8E5,
  0xA8E6,
  0xA8E7,
  0xA8E8,
  0xA8E9,
  0xA8EA,
  0xA8EB,
  0xA8EC,
  0xA8ED,
  0xA8EE,
  0xA8EF,
  0xA8F0,
  0xA8F1,
  0xAAB0,
  0xAAB2,
  0xAAB3,
  0xAAB7,
  0xAAB8,
  0xAABE,
  0xAABF,
  0xAAC1,
  0xFE20,
  0xFE21,
  0xFE22,
  0xFE23,
  0xFE24,
  0xFE25,
  0xFE26,
  0x10A0F,
  0x10A38,
  0x1D185,
  0x1D186,
  0x1D187,
  0x1D188,
  0x1D189,
  0x1D1AA,
  0x1D1AB,
  0x1D1AC,
  0x1D1AD,
  0x1D242,
  0x1D243,
  0x1D244,
}

--- O caractere que marca uma célula de imagem.
M.PLACEHOLDER = 0x10EEEE

--- Maior número de linhas ou de colunas que o protocolo sabe numerar sem o terceiro diacrítico.
M.MAX_CELLS = #M.DIACRITICS

--- Faixa de ids que o deckle usa: o que a cor de primeiro plano carrega nos dois modos de cor
--- (256 cores e RGB). O piso é 16 porque o Neovim escreve as cores 0 a 15 como `ESC[30m`..`ESC[97m`
--- e a documentação do kitty só mostra o id na forma `38;5;<id>`: de 16 em diante o Neovim emite
--- exatamente essa.
M.MIN_ID = 16
M.MAX_ID = 255

--- Tamanho máximo de um pedaço de dados em base64 (o protocolo permite até 4096 por escape).
M.CHUNK = 4096

local ESC = "\27"

--- UTF-8 de um ponto de código. O LuaJIT não tem `utf8.char`.
---@param cp integer
---@return string
local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

---@type string[]
local marks = {}
for i, cp in ipairs(M.DIACRITICS) do
  marks[i] = utf8_char(cp)
end

local PLACEHOLDER = utf8_char(M.PLACEHOLDER)

--- Uma célula de placeholder: o caractere, o diacrítico da linha e o da coluna (0-indexados).
---@param row integer
---@param col integer
---@return string
function M.cell(row, col)
  local r, c = marks[row + 1], marks[col + 1]
  assert(r and c, "image cell outside the diacritics table")
  return PLACEHOLDER .. r .. c
end

--- Uma linha de `cols` células da linha `row` da imagem.
---@param row integer
---@param cols integer
---@return string
function M.placeholder_row(row, cols)
  local cells = {}
  for col = 0, cols - 1 do
    cells[#cells + 1] = M.cell(row, col)
  end
  return table.concat(cells)
end

--- Um escape do protocolo: `ESC _ G <chaves> [; <carga>] ESC \`.
---@param keys string
---@param payload string|nil
---@return string
local function escape(keys, payload)
  return ESC .. "_G" .. keys .. (payload and (";" .. payload) or "") .. ESC .. "\\"
end

---@param data string
---@return string
local function base64(data)
  return vim.base64.encode(data)
end

--- Transmite um PNG **por caminho** (`t=f`): o terminal lê o arquivo, que precisa estar na máquina
--- dele. `q=2` cala as respostas do terminal, que cairiam na entrada do Neovim como teclas.
---@param id integer
---@param path string  caminho absoluto
---@return string[] escapes
function M.transmit_file(id, path)
  return { escape(("a=t,f=100,t=f,i=%d,q=2"):format(id), base64(path)) }
end

--- Transmite um PNG **pelos próprios bytes** (`t=d`), em pedaços de até `CHUNK` de base64. É o
--- caminho de quem não divide o disco com o terminal (SSH). `m=1` em todos os pedaços menos o
--- último, e os seguintes ao primeiro só carregam `m` e `q`, como manda o protocolo.
---@param id integer
---@param data string  o conteúdo do arquivo PNG
---@return string[] escapes
function M.transmit_data(id, data)
  local encoded = base64(data)
  local out = {}
  local total = math.max(1, math.ceil(#encoded / M.CHUNK))
  for index = 1, total do
    local chunk = encoded:sub((index - 1) * M.CHUNK + 1, index * M.CHUNK)
    local more = index < total and 1 or 0
    if total == 1 then
      out[1] = escape(("a=t,f=100,t=d,i=%d,q=2"):format(id), chunk)
    elseif index == 1 then
      out[#out + 1] = escape(("a=t,f=100,t=d,i=%d,q=2,m=%d"):format(id, more), chunk)
    else
      out[#out + 1] = escape(("m=%d,q=2"):format(more), chunk)
    end
  end
  return out
end

--- Cria o posicionamento virtual da imagem `id`, de `cols` por `rows` células. O kitty encaixa a
--- imagem nesse retângulo mantendo a proporção. `C=1`: não mexe no cursor.
---@param id integer
---@param cols integer
---@param rows integer
---@return string[] escapes
function M.place(id, cols, rows)
  return { escape(("a=p,U=1,i=%d,c=%d,r=%d,C=1,q=2"):format(id, cols, rows)) }
end

--- Apaga a imagem `id`, os posicionamentos dela e os dados transmitidos (`d=I`, a forma em
--- maiúscula, que também libera a memória do terminal). Só essa imagem: nada de `d=a`, que
--- apagaria também as de outros programas na mesma janela.
---@param id integer
---@return string[] escapes
function M.delete(id)
  return { escape(("a=d,d=I,i=%d,q=2"):format(id)) }
end

--- Embrulha um escape para o tmux repassá-lo ao terminal (`DCS tmux ; ... ST`, com cada ESC
--- dobrado). Exige `allow-passthrough` ligado no tmux.
---@param sequence string
---@return string
function M.tmux_wrap(sequence)
  return ESC .. "Ptmux;" .. sequence:gsub(ESC, ESC .. ESC) .. ESC .. "\\"
end

return M
