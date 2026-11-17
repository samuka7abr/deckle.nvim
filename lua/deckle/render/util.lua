--- Apoio compartilhado pelos módulos de render: medida de largura, divisão em clusters e as
--- duas operações que todo contêiner (`quote`, `list`) precisa, prefixar linhas e empilhar
--- blocos, ambas mantendo as marcas coerentes com as linhas.

local M = {}

--- Largura mínima de conteúdo que um bloco recebe. Contêineres aninhados fundo estreitam a
--- largura a cada nível, e abaixo disto o texto viraria uma coluna de uma letra: o conteúdo
--- passa a transbordar a janela em vez de encolher mais.
M.MIN_WIDTH = 10

--- Largura de display de `s`, em células. Nunca `#s`: emoji e CJK ocupam duas células e um
--- caractere combinante, nenhuma (CLAUDE.md, regra 6).
---
--- ASCII imprimível não precisa perguntar ao Neovim: 1 byte é 1 célula. O resto (inclusive
--- tab e caractere de controle, cuja largura depende do contexto) vai para `strdisplaywidth`.
---@param s string
---@return integer
function M.width(s)
  if not s:find("[^\32-\126]") then
    return #s
  end
  return vim.fn.strdisplaywidth(s)
end

--- Divide `s` em clusters de grafemas: o que o terminal desenha como uma unidade. Uma
--- sequência com ZWJ, um emoji com tom de pele e uma letra com acento combinante saem como
--- um elemento só, e por isso nunca são partidos numa quebra de linha.
---@param s string
---@return string[]
function M.clusters(s)
  return vim.fn.split(s, "\\zs")
end

--- Acrescenta `more_lines` e `more_marks` ao fim de `lines` e `marks`, deslocando as linhas
--- das marcas. As tabelas de `more_marks` passam a pertencer ao destino.
---@param lines string[]
---@param marks deckle.Mark[]
---@param more_lines string[]
---@param more_marks deckle.Mark[]
function M.append(lines, marks, more_lines, more_marks)
  local offset = #lines
  for _, line in ipairs(more_lines) do
    lines[#lines + 1] = line
  end
  for _, mark in ipairs(more_marks) do
    mark.row = mark.row + offset
    marks[#marks + 1] = mark
  end
end

--- Prefixa as linhas de um bloco já renderizado e desloca as marcas na horizontal.
---
--- Linha vazia recebe o prefixo sem o espaço à direita (a borda de um quote continua
--- contínua e nenhuma linha termina em espaço). Altera `lines` e `marks` no lugar.
---@param lines string[]
---@param marks deckle.Mark[]
---@param first string prefixo da primeira linha
---@param rest string prefixo das demais
---@return integer[] cuts bytes de prefixo de cada linha (índice 1), para marcas do chamador
function M.prefix(lines, marks, first, rest)
  local cuts = {}
  for i, line in ipairs(lines) do
    local prefix = i == 1 and first or rest
    if line == "" then
      prefix = prefix:gsub("%s+$", "")
    end
    lines[i] = prefix .. line
    cuts[i] = #prefix
  end
  for _, mark in ipairs(marks) do
    mark.col = mark.col + cuts[mark.row + 1]
    mark.end_col = mark.end_col + cuts[mark.row + 1]
  end
  return cuts
end

return M
