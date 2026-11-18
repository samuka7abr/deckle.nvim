--- Escapes ANSI (SGR) -> texto limpo + marcas de highlight.
---
--- O `merman-ascii` desenha o Mermaid em cores quando o modo de cor é `Ansi16`, `Ansi256` ou
--- `TrueColor`: o texto sai com escapes `ESC [ ... m` no meio. O preview não entende escapes
--- (o buffer guardaria os bytes), então este módulo os tira e devolve, no lugar, o texto limpo e
--- as marcas (ver `deckle.render`) que pintam o mesmo trecho. Função pura do texto, exceto pela
--- criação dos grupos de highlight (ver abaixo).
---
--- # Contrato
---
--- ```lua
--- local ansi = require("deckle.render.ansi")
--- local clean, marks = ansi.parse(lines)  -- lines: string[], com escapes SGR
--- -- clean: string[], uma linha por linha de entrada, sem NENHUM byte ESC
--- -- marks: { { row = 0, col = 4, end_col = 9, hl = "DeckleMermaidC_ff8800_1e1e2e_b" } }
--- ansi.has_escapes(lines)                  -- boolean: alguma linha tem ESC?
--- ```
---
--- `row` é a linha em `clean` (0-indexada), `col` e `end_col` são **bytes** 0-indexados com fim
--- exclusivo, medidos em `clean` (nunca em células, nunca na entrada): é o que
--- `nvim_buf_set_extmark` espera. Uma marca cobre uma linha só. As marcas saem em ordem de linha
--- e de coluna, sem se sobrepor, e as vizinhas com o mesmo grupo são fundidas numa. Texto sem
--- estilo não gera marca. As marcas não levam `priority`: quem as escreve no buffer decide.
---
--- # O que se entende
---
--- SGR (`ESC [ <params> m`, parâmetros separados por `;`, vários num escape só):
---
--- * `0` (ou vazio) zera tudo; `1` negrito, `22` o desliga; `3`/`23` itálico; `4`/`24`
---   sublinhado; `7`/`27` vídeo reverso; `9`/`29` tachado;
--- * `30-37` e `90-97` (frente), `40-47` e `100-107` (fundo): as 16 cores do terminal;
--- * `38;5;n` e `48;5;n`: paleta de 256 cores; `38;2;r;g;b` e `48;2;r;g;b`: TrueColor. A forma
---   com dois-pontos (`38:2::r:g:b`, `38:5:n`, `4:3`) também;
--- * `39` e `49` voltam a cor de frente e a de fundo ao padrão.
---
--- Todo o resto é descartado sem erro: SGR que não se conhece (`2`, `5`, `58;...`), CSI com outro
--- final (`ESC [ 2 K`), CSI privado (`ESC [ ? 25 h`), OSC e os demais "strings" de controle
--- (terminados por BEL ou `ESC \`), escapes de dois bytes e de designação de charset. Escape
--- truncado no fim da linha (`ESC [ 38 ; 2`) é descartado até o fim dela, e um ESC solto é só
--- removido: `parse` nunca lança por causa do conteúdo.
---
--- # Estado entre linhas
---
--- O estilo ativo **atravessa** o fim da linha, como num terminal: um escape que liga uma cor e
--- nenhum `ESC [ 0 m` depois a mantêm na linha seguinte (que ganha a marca desde a coluna 0).
--- O estado começa liso a cada chamada de `parse`. O merman 0.10.0, que é quem alimenta este
--- módulo, **zera a cada linha**: em todo modo de cor, cada trecho com estilo termina em `ESC [ 0 m`
--- (também antes de um trecho de outro estilo, e no fim da linha), de modo que nenhuma linha
--- depende da anterior. Ele só emite fundo e frente (`38;2;r;g;b` e `48;2;r;g;b` em TrueColor,
--- `38;5;n` e `48;5;n` em Ansi256, `30-37`/`90-97` e `40-47`/`100-107` em Ansi16): nunca negrito,
--- itálico nem sublinhado. Com o tema padrão, **todo** glifo leva uma cor de frente (até o texto
--- comum), então o preview colorido tem uma marca por trecho, não só nos nós com `classDef`. O
--- texto de um nó de flowchart com `fill` leva só a frente (`color`): o fundo (`fill`) vem nas
--- células de preenchimento ao redor dele, não nas do rótulo, e as duas viram marcas vizinhas de
--- grupos diferentes (`DeckleMermaidC_155724_` para o texto, `DeckleMermaidC__d4edda` para o resto).
---
--- # Grupos de highlight
---
--- Cada estilo distinto vira um grupo, criado na hora por `nvim_set_hl` e guardado, com nome
--- determinístico:
---
--- ```
--- DeckleMermaidC_<frente>_<fundo>[_<atributos>]
--- ```
---
--- `<frente>` e `<fundo>` são seis dígitos hexadecimais minúsculos (`ff8800`), `aN` (a cor `N` de
--- 0 a 15 do terminal, que sai de `vim.g.terminal_color_N` e, sem ela, de uma paleta xterm) ou
--- vazio (sem cor). `<atributos>` é o que sobra de `b` (negrito), `i`, `u`, `r` (reverso) e `s`
--- (tachado), nessa ordem, e some quando não há nenhum. Exemplos: `DeckleMermaidC_ff8800_1e1e2e_b`
--- (laranja sobre cinza, em negrito), `DeckleMermaidC_00ff88_` (só frente), `DeckleMermaidC__0088ff`
--- (só fundo). O mesmo estilo dá sempre o mesmo grupo, criado uma vez só.
---
--- `:colorscheme` apaga os grupos feitos por `nvim_set_hl`; o autocmd `ColorScheme` do augroup
--- `deckle_mermaid_ansi` (próprio, para não tocar em `deckle.highlight`) refaz todos os que foram
--- criados. Os grupos não são `default`: a cor vem do diagrama, não do esquema do usuário, e não
--- entram em `deckle.highlight.groups` (que lista só grupos fixos, com tag no `:help`).

local M = {}

local find, sub, byte, concat = string.find, string.sub, string.byte, table.concat

--- Prefixo dos grupos. Termina em `_` de propósito: o teste que confere os grupos dos módulos de
--- render procura nomes entre aspas sem `_`, e estes não são fixos.
local PREFIX = "DeckleMermaidC_"

--- Augroup do autocmd `ColorScheme`. Em minúsculas, como nome de augroup e não de grupo de
--- highlight: `"Deckle<Nome>"` entre aspas, num módulo de render, é lido como grupo fixo e tem que
--- existir em `deckle.highlight.groups`.
local AUGROUP = "deckle_mermaid_ansi"

--- Quantas transições `(estilo, parâmetros) -> estilo` ficam memorizadas. Um diagrama tem poucas
--- dezenas; o limite só impede que uma saída hostil, com milhões de cores, encha a memória (passado
--- dele a conta se refaz a cada escape, sem erro).
local MEMO_LIMIT = 20000

-- ---------------------------------------------------------------------------------------
-- Cores
-- ---------------------------------------------------------------------------------------

--- As 16 cores do terminal, quando o esquema não define `vim.g.terminal_color_N`.
local ANSI16 = {
  "#000000",
  "#cd0000",
  "#00cd00",
  "#cdcd00",
  "#0000ee",
  "#cd00cd",
  "#00cdcd",
  "#e5e5e5",
  "#7f7f7f",
  "#ff0000",
  "#00ff00",
  "#ffff00",
  "#5c5cff",
  "#ff00ff",
  "#00ffff",
  "#ffffff",
}

--- Token de cada índice da paleta de 256 cores: `aN` para as 16 primeiras (que seguem o
--- esquema), hexadecimal para o cubo 6x6x6 e para os 24 tons de cinza.
---@type string[]  indexado de 0 a 255
local PALETTE256 = {}
do
  local levels = { 0, 95, 135, 175, 215, 255 } -- o nível `n` do cubo é `levels[n + 1]`
  for index = 0, 15 do
    PALETTE256[index] = "a" .. index
  end
  for index = 16, 231 do
    local cube = index - 16
    PALETTE256[index] = string.format(
      "%02x%02x%02x",
      levels[math.floor(cube / 36) + 1],
      levels[math.floor(cube / 6) % 6 + 1],
      levels[cube % 6 + 1]
    )
  end
  for index = 232, 255 do
    local gray = 8 + 10 * (index - 232)
    PALETTE256[index] = string.format("%02x%02x%02x", gray, gray, gray)
  end
end

--- Valor de um token de cor para o `nvim_set_hl`.
---@param token string
---@return string
local function color_value(token)
  if #token <= 3 then -- `aN`; o hexadecimal tem sempre seis dígitos (e pode começar com `a`)
    local index = tonumber(sub(token, 2))
    return vim.g["terminal_color_" .. index] or ANSI16[index + 1]
  end
  return "#" .. token
end

--- Token de um `r;g;b` (cada um um inteiro de 0 a 255), ou `nil`.
---@param r any
---@param g any
---@param b any
---@return string|nil
local function rgb_token(r, g, b)
  r, g, b = tonumber(r), tonumber(g), tonumber(b)
  if not (r and g and b) then
    return nil
  end
  if r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255 then
    return nil
  end
  return string.format("%02x%02x%02x", r, g, b)
end

-- ---------------------------------------------------------------------------------------
-- Estilos
-- ---------------------------------------------------------------------------------------
--
-- Um estilo é imutável e internado: o mesmo (frente, fundo, atributos) é sempre a mesma tabela.
-- Cada estilo guarda as transições já calculadas por string de parâmetros SGR (`next`), então o
-- caso comum, um escape que o diagrama já usou, custa uma busca em tabela e nenhuma conta.

---@class deckle.AnsiStyle
---@field fg string|nil      token de cor (ver `PALETTE256`)
---@field bg string|nil
---@field bold boolean
---@field italic boolean
---@field underline boolean
---@field reverse boolean
---@field strike boolean
---@field name string|nil    grupo de highlight; `nil` quando o estilo é liso
---@field next table<string, deckle.AnsiStyle>

---@type table<string, deckle.AnsiStyle>
local styles = {}
local memo_count = 0

---@return deckle.AnsiStyle
local function intern(fg, bg, bold, italic, underline, reverse, strike)
  local flags = (bold and "b" or "")
    .. (italic and "i" or "")
    .. (underline and "u" or "")
    .. (reverse and "r" or "")
    .. (strike and "s" or "")
  local key = (fg or "") .. "_" .. (bg or "") .. "_" .. flags
  local style = styles[key]
  if style then
    return style
  end
  local name
  if fg or bg or flags ~= "" then
    name = PREFIX .. (fg or "") .. "_" .. (bg or "") .. (flags ~= "" and "_" .. flags or "")
  end
  style = {
    fg = fg,
    bg = bg,
    bold = bold,
    italic = italic,
    underline = underline,
    reverse = reverse,
    strike = strike,
    name = name,
    next = {},
  }
  styles[key] = style
  return style
end

local PLAIN = intern(nil, nil, false, false, false, false, false)

--- Cor de um `38`/`48`/`58` escrito com `;`. `list` são os parâmetros, `i` o índice do `38`.
---@param list string[]
---@param i integer
---@return string|nil token
---@return integer next_i  índice do último parâmetro consumido
local function extended_color(list, i)
  local mode = tonumber(list[i + 1])
  if mode == 5 then
    local index = tonumber(list[i + 2])
    return index and PALETTE256[index], i + 2
  elseif mode == 2 then
    return rgb_token(list[i + 2], list[i + 3], list[i + 4]), i + 4
  end
  return nil, i + 1 -- modo desconhecido: cai o `38` e o modo, o resto segue
end

--- Cor de um `38:...`/`48:...` escrito com `:` (`38:5:n`, `38:2:r:g:b`, `38:2::r:g:b`).
---@param parts string[]
---@return string|nil
local function colon_color(parts)
  local mode = tonumber(parts[2])
  if mode == 5 then
    local index = tonumber(parts[3])
    return index and PALETTE256[index]
  elseif mode == 2 and #parts >= 5 then
    -- O identificador de espaço de cor (`38:2::r:g:b`) é opcional: vale o fim da lista.
    return rgb_token(parts[#parts - 2], parts[#parts - 1], parts[#parts])
  end
  return nil
end

--- O estilo que resulta de aplicar `params` (o miolo de `ESC [ ... m`) a `style`.
---@param style deckle.AnsiStyle
---@param params string
---@return deckle.AnsiStyle
local function compute(style, params)
  local fg, bg = style.fg, style.bg
  local bold, italic, underline = style.bold, style.italic, style.underline
  local reverse, strike = style.reverse, style.strike

  local list, count = {}, 0
  for token in (params .. ";"):gmatch("([^;]*);") do
    count = count + 1
    list[count] = token
  end

  local i = 1
  while i <= count do
    local token = list[i]
    if find(token, ":", 1, true) then
      local parts = vim.split(token, ":", { plain = true })
      local head = tonumber(parts[1])
      if head == 38 then
        fg = colon_color(parts) or fg
      elseif head == 48 then
        bg = colon_color(parts) or bg
      elseif head == 4 then
        underline = parts[2] ~= "0"
      end
    else
      local code = token == "" and 0 or tonumber(token)
      if code == 0 then
        fg, bg = nil, nil
        bold, italic, underline, reverse, strike = false, false, false, false, false
      elseif code == 1 then
        bold = true
      elseif code == 3 then
        italic = true
      elseif code == 4 then
        underline = true
      elseif code == 7 then
        reverse = true
      elseif code == 9 then
        strike = true
      elseif code == 22 then
        bold = false
      elseif code == 23 then
        italic = false
      elseif code == 24 then
        underline = false
      elseif code == 27 then
        reverse = false
      elseif code == 29 then
        strike = false
      elseif code == 39 then
        fg = nil
      elseif code == 49 then
        bg = nil
      elseif code and code >= 30 and code <= 37 then
        fg = PALETTE256[code - 30]
      elseif code and code >= 40 and code <= 47 then
        bg = PALETTE256[code - 40]
      elseif code and code >= 90 and code <= 97 then
        fg = PALETTE256[code - 90 + 8]
      elseif code and code >= 100 and code <= 107 then
        bg = PALETTE256[code - 100 + 8]
      elseif code == 38 then
        local token_color
        token_color, i = extended_color(list, i)
        fg = token_color or fg
      elseif code == 48 then
        local token_color
        token_color, i = extended_color(list, i)
        bg = token_color or bg
      elseif code == 58 then
        -- Cor do sublinhado: o grupo não a guarda; só se pula o que ela consome.
        local _skipped
        _skipped, i = extended_color(list, i)
      end
    end
    i = i + 1
  end

  return intern(fg, bg, bold, italic, underline, reverse, strike)
end

---@param style deckle.AnsiStyle
---@param params string
---@return deckle.AnsiStyle
local function step(style, params)
  local following = style.next[params]
  if following then
    return following
  end
  following = compute(style, params)
  if memo_count < MEMO_LIMIT then
    style.next[params] = following
    memo_count = memo_count + 1
  end
  return following
end

-- ---------------------------------------------------------------------------------------
-- Grupos de highlight
-- ---------------------------------------------------------------------------------------

--- Estilos cujo grupo já foi criado, por nome, para o `ColorScheme` refazê-los.
---@type table<string, deckle.AnsiStyle>
local defined = {}

---@param style deckle.AnsiStyle
local function define(style)
  local spec = {}
  if style.fg then
    spec.fg = color_value(style.fg)
  end
  if style.bg then
    spec.bg = color_value(style.bg)
  end
  if style.bold then
    spec.bold = true
  end
  if style.italic then
    spec.italic = true
  end
  if style.underline then
    spec.underline = true
  end
  if style.reverse then
    spec.reverse = true
  end
  if style.strike then
    spec.strikethrough = true
  end
  vim.api.nvim_set_hl(0, style.name, spec)
end

--- Liga o autocmd `ColorScheme` que refaz os grupos. Idempotente: chamar de novo recria o
--- augroup (`clear = true`) e deixa um autocmd só. `parse` chama sozinho antes do primeiro grupo.
function M.setup()
  vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = AUGROUP,
    desc = "deckle: redefine the ANSI highlight groups of the mermaid renderer",
    callback = function()
      for _, style in pairs(defined) do
        define(style)
      end
    end,
  })
end

---@param style deckle.AnsiStyle
local function ensure(style)
  if next(defined) == nil then
    M.setup()
  end
  if not defined[style.name] then
    defined[style.name] = style
    define(style)
  end
end

-- ---------------------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------------------

--- Acrescenta `text` (já sem escapes) a uma linha, com o estilo ativo. Funde com a marca
--- anterior quando ela termina exatamente onde `text` começa e tem o mesmo grupo.
---@param style deckle.AnsiStyle
---@param text string
---@param row integer
---@param col integer         byte onde `text` começa em `clean`
---@param marks deckle.Mark[]
---@param last deckle.Mark|nil  última marca desta linha
---@param ensured table<deckle.AnsiStyle, boolean>
---@return integer col        byte onde `text` termina
---@return deckle.Mark|nil last
local function emit(style, text, row, col, marks, last, ensured)
  local stop = col + #text
  local name = style.name
  if name and stop > col then
    if last and last.hl == name and last.end_col == col then
      last.end_col = stop
    else
      if not ensured[style] then
        ensure(style)
        ensured[style] = true
      end
      last = { row = row, col = col, end_col = stop, hl = name }
      marks[#marks + 1] = last
    end
  end
  return stop, last
end

--- Consome o escape que começa em `esc` (a posição de um ESC) e que o caminho rápido de
--- `parse_line` não pegou. Um SGR com marcador privado, ou com um parâmetro estranho, chega
--- aqui; só um SGR de verdade muda o estilo.
---@param line string
---@param esc integer  posição do ESC
---@param len integer  `#line`
---@param style deckle.AnsiStyle
---@return integer pos  onde o texto recomeça
---@return deckle.AnsiStyle|nil style  o novo estilo, ou `nil` se o escape não é SGR
local function skip_escape(line, esc, len, style)
  local intro = byte(line, esc + 1)
  if intro == 91 then -- `[`: CSI
    local _, stop, params, final = find(line, "^([0-?]*)[ -/]*([@-~])", esc + 2)
    if stop then
      -- `<`, `=`, `>` e `?` no começo são CSI privado (`ESC [ > 4 ; 2 m`), não SGR.
      local marker = byte(params, 1)
      if final == "m" and not (marker and marker >= 60) then
        return stop + 1, step(style, params)
      end
      return stop + 1, nil
    end
    -- Sem final: truncado no fim da linha, ou cancelado por outro caractere. Cai fora o que já
    -- foi lido da sequência, e o resto segue como texto.
    local _, partial = find(line, "^[0-?]*[ -/]*", esc + 2)
    return partial + 1, nil
  elseif intro == 93 or intro == 80 or intro == 88 or intro == 94 or intro == 95 then
    -- `]` (OSC), `P` (DCS), `X` (SOS), `^` (PM), `_` (APC): textos de controle que vão até BEL
    -- ou `ESC \`, ou até o fim da linha quando ninguém os fecha.
    local bel = find(line, "\7", esc + 2, true)
    local terminator = find(line, "\27\\", esc + 2, true)
    if bel and (not terminator or bel < terminator) then
      return bel + 1, nil
    elseif terminator then
      return terminator + 2, nil
    end
    return len + 1, nil
  elseif intro and intro >= 32 and intro <= 47 then
    -- `ESC ( B` e afins: intermediários e um final.
    local _, stop = find(line, "^[ -/]*[0-~]", esc + 1)
    return (stop or esc + 1) + 1, nil
  elseif intro and intro >= 48 and intro <= 126 then
    return esc + 2, nil -- `ESC 7`, `ESC M`, `ESC =`...: dois bytes
  end
  return esc + 1, nil -- ESC solto (ou seguido de um byte de controle): só ele cai
end

--- Uma linha. Devolve o texto limpo e o estilo ativo no fim dela.
---@param line string
---@param row integer  0-indexado
---@param style deckle.AnsiStyle  o estilo ativo no começo da linha
---@param marks deckle.Mark[]
---@param ensured table<deckle.AnsiStyle, boolean>
---@return string clean
---@return deckle.AnsiStyle style
local function parse_line(line, row, style, marks, ensured)
  local parts, count = {}, 0
  local col, last = 0, nil
  local pos, len = 1, #line

  while pos <= len do
    -- Caminho rápido, o de quase todo escape do merman: o texto até o próximo ESC e um SGR sem
    -- marcador privado, numa busca só.
    local _, stop, text, params = find(line, "^([^\27]*)\27%[([0-9;]*)m", pos)
    local following
    if stop then
      following = step(style, params)
      pos = stop + 1
    else
      local esc = find(line, "\27", pos, true)
      text = sub(line, pos, (esc or len + 1) - 1)
      if esc then
        pos, following = skip_escape(line, esc, len, style)
      else
        pos = len + 1
      end
    end

    if text ~= "" then
      count = count + 1
      parts[count] = text
      col, last = emit(style, text, row, col, marks, last, ensured)
    end
    style = following or style
  end

  return concat(parts), style
end

--- Alguma linha tem um byte ESC?
---@param lines string[]
---@return boolean
function M.has_escapes(lines)
  for _, line in ipairs(lines or {}) do
    if find(line, "\27", 1, true) then
      return true
    end
  end
  return false
end

--- Tira os escapes de `lines` e devolve o texto limpo e as marcas que o pintam. Ver o contrato
--- no topo do módulo.
---@param lines string[]
---@return string[] clean_lines
---@return deckle.Mark[] marks
function M.parse(lines)
  local clean, marks = {}, {}
  local ensured = {}
  local style = PLAIN

  for index, line in ipairs(lines or {}) do
    if find(line, "\27", 1, true) then
      clean[index], style = parse_line(line, index - 1, style, marks, ensured)
    else
      -- Sem escape na linha: ela inteira tem o estilo que vinha da anterior.
      clean[index] = line
      if style.name and line ~= "" then
        emit(style, line, index - 1, 0, marks, nil, ensured)
      end
    end
  end

  return clean, marks
end

return M
