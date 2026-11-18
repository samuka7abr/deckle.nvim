--- Sincronia de scroll entre o buffer fonte e o preview (fase 3).
---
--- O preview é um buffer separado, e o texto dele não tem as mesmas linhas do fonte: um
--- parágrafo quebrado na largura da janela ocupa mais linhas, um bloco de mermaid ocupa 40 onde
--- o fonte tem 6. Quem faz a ponte é o mapa `deckle.MapEntry[]` que o render devolve (ver
--- `deckle.render`): um intervalo do preview e um do fonte por bloco de topo, em ordem nos dois
--- lados. Este módulo tem duas partes.
---
--- # Busca (pura, sem Neovim)
---
--- `locate`, `src_to_preview` e `preview_to_src` são funções do mapa e de um número de linha.
--- Não tocam em buffer, janela nem config, e custam O(log n) por consulta. O mapa já é ordenado
--- nos dois lados, então não há dois arrays à parte: a busca binária corre sobre as próprias
--- entradas, olhando `src_start` ou `preview_start`.
---
--- Todas as linhas são 0-indexadas, e os fins dos intervalos são exclusivos, como em todo o
--- projeto. A linha resolve assim:
---
--- * **dentro de um bloco:** interpolação linear pelo deslocamento, `destino_start +
---   floor(deslocamento * tamanho_destino / tamanho_origem)`. Um bloco de N linhas do fonte que
---   vira 1 no preview cai sempre nessa linha; um de 1 que vira N cai na primeira; com
---   tamanhos iguais a conta é a identidade. É aproximação (o wrap não preserva proporção
---   linha a linha), mas é monótona e fica sempre dentro do bloco;
--- * **entre dois blocos** (a linha em branco que o render põe entre eles não pertence a
---   nenhum): o bloco mais próximo, medido da linha até a **borda** dele (a última linha do
---   bloco de cima, a primeira do de baixo). **Empate vale o bloco de cima**; como o render
---   deixa uma linha em branco entre blocos, é o caso comum;
--- * **antes do primeiro bloco:** o primeiro, na primeira linha dele;
--- * **depois do último:** o último, na última linha dele;
--- * **mapa vazio:** `nil`.
---
--- Quando a resolução cai fora do bloco (nos três casos acima), o resultado é a borda do bloco
--- escolhido no outro lado, sem interpolar.
---
--- # Autocmds (Neovim)
---
--- `attach(src)` e `detach(src)` são chamadas por `deckle.preview` no mesmo ponto em que ele
--- registra e remove os próprios autocmds vivos. Com `sync = "off"` o `attach` não faz nada: não
--- existe autocmd nenhum, nem um ouvinte global esperando. Com `sync = "cursor"`, por preview
--- aberto, no augroup `deckle_sync_<src>`:
---
--- * `CursorMoved` no fonte: move o cursor do preview para o bloco do cursor do fonte;
--- * `CursorMoved` no preview: o inverso;
--- * `User DeckleRender`: relê o mapa (`preview.state(src).map`). O mapa nunca é guardado além do
---   render a que pertence; e, se quem está na janela do fonte é o usuário, realinha o preview,
---   porque o render pode ter mudado a altura dos blocos. O primeiro render depois do `attach`
---   realinha sempre: é o que leva o preview para onde o cursor do fonte já estava ao abrir.
---
--- Só `CursorMoved`, não `CursorMovedI`: o preview também não re-renderiza digitando.
---
--- Além de mover o cursor, o destino é rolado (`winrestview`) para que a linha de chegada fique
--- na mesma altura relativa da janela em que o cursor de origem está. No fonte com `wrap` ligado
--- é aproximação (a altura vem em linhas de tela e o `topline` em linhas do buffer), e o Neovim
--- corrige se o cursor sair da janela.
---
--- # Anti-loop
---
--- Mover o cursor de um lado não pode mandar o outro de volta. Dois mecanismos, porque as
--- causas são duas:
---
--- * `busy`: sinal de reentrada. Fica ligado enquanto o módulo mexe na outra janela e, nesse
---   intervalo, todo `CursorMoved` é ignorado. Pega o evento síncrono (um autocmd de terceiro
---   que reage ao cursor movido e redispara o evento).
--- * `expect`: a linha para onde o próprio módulo levou o cursor de cada lado. O `CursorMoved`
---   de uma janela que não é a atual só dispara depois, quando o usuário entra nela, e chega
---   com o cursor onde o módulo o pôs. Esse evento é ignorado uma vez. Sem isto, passar de uma
---   janela para a outra empurraria o cursor da primeira para a linha interpolada, e num bloco
---   de 40 linhas para 6 o cursor do fonte saltaria só por trocar de janela.
---
--- A configuração é lida no `attach`: mudar `sync` com um preview aberto vale na abertura
--- seguinte.

local M = {}

-- ---------------------------------------------------------------------------------------
-- Busca (pura)
-- ---------------------------------------------------------------------------------------

---@alias deckle.SyncSide "src"|"preview"

--- Acha o bloco do mapa que a linha `line` resolve, por busca binária.
---
--- Devolve o índice da entrada e se a linha está **dentro** dela. Fora de qualquer bloco, o
--- índice é o do bloco mais próximo (regras no topo do módulo) e o segundo valor é `false`.
---@param map deckle.MapEntry[]
---@param side deckle.SyncSide  qual lado do mapa `line` mede
---@param line integer          0-indexada
---@return integer|nil index    `nil` só com o mapa vazio
---@return boolean inside
function M.locate(map, side, line)
  local count = #map
  if count == 0 then
    return nil, false
  end
  local start_key, end_key = side .. "_start", side .. "_end"

  -- Maior índice cuja entrada começa em `line` ou antes. Invariante: as entradas `1..low`
  -- começam em `line` ou antes, as de `high + 1..count` começam depois.
  local low, high = 0, count
  while low < high do
    local mid = math.floor((low + high + 1) / 2)
    if map[mid][start_key] <= line then
      low = mid
    else
      high = mid - 1
    end
  end

  if low == 0 then
    return 1, false -- antes do primeiro bloco
  end
  local entry = map[low]
  if line < entry[end_key] then
    return low, true
  end
  if low == count then
    return count, false -- depois do último bloco
  end

  -- Entre `low` e `low + 1`. Distância até a borda de cada um; empate fica com o de cima.
  local above = line - (entry[end_key] - 1)
  local below = map[low + 1][start_key] - line
  if below < above then
    return low + 1, false
  end
  return low, false
end

--- `offset` dentro de um intervalo de `from_len` linhas, levado para um de `to_len` que começa
--- em `base`. Monótona, e `base <= resultado < base + max(to_len, 1)`.
---@param offset integer
---@param from_len integer
---@param base integer
---@param to_len integer
---@return integer
local function interpolate(offset, from_len, base, to_len)
  if from_len < 1 or to_len < 1 then
    return base
  end
  return base + math.floor(offset * to_len / from_len)
end

--- Resolve `line` do lado `side` para uma linha do outro lado.
---@param map deckle.MapEntry[]
---@param side deckle.SyncSide
---@param line integer
---@return integer|nil
local function resolve(map, side, line)
  local index, inside = M.locate(map, side, line)
  if not index then
    return nil
  end
  local entry = map[index]
  local other = side == "src" and "preview" or "src"
  local from_start, from_end = entry[side .. "_start"], entry[side .. "_end"]
  local to_start, to_end = entry[other .. "_start"], entry[other .. "_end"]

  if inside then
    return interpolate(line - from_start, from_end - from_start, to_start, to_end - to_start)
  end
  if line < from_start then
    return to_start
  end
  return math.max(to_start, to_end - 1)
end

--- Linha do preview que corresponde à linha `line` do fonte, ou `nil` com o mapa vazio.
---@param map deckle.MapEntry[]
---@param line integer  0-indexada
---@return integer|nil
function M.src_to_preview(map, line)
  return resolve(map, "src", line)
end

--- Linha do fonte que corresponde à linha `line` do preview, ou `nil` com o mapa vazio.
---@param map deckle.MapEntry[]
---@param line integer  0-indexada
---@return integer|nil
function M.preview_to_src(map, line)
  return resolve(map, "preview", line)
end

-- ---------------------------------------------------------------------------------------
-- Autocmds
-- ---------------------------------------------------------------------------------------

---@class deckle.SyncEntry
---@field src integer                   buffer fonte
---@field buf integer                   buffer de preview
---@field win integer                   janela de preview
---@field group integer                 augroup dos autocmds de sync
---@field map deckle.MapEntry[]         mapa do último render
---@field busy boolean                  sinal de reentrada
---@field expect { src: integer|nil, preview: integer|nil }  linha (0-indexada) a que o módulo levou o cursor de cada lado
---@field src_win integer|nil           última janela do fonte em que o cursor andou
---@field rendered boolean              já houve um render depois do `attach`

---@type table<integer, deckle.SyncEntry>
local entries = {}

---@return table
local function config()
  return require("deckle.config").options
end

--- Roda `fn` com `busy` ligado e o desliga sempre, mesmo que `fn` lance. Um erro aqui não pode
--- deixar o sinal preso (a sincronia morreria calada) nem encher a tela a cada movimento.
---@param entry deckle.SyncEntry
---@param fn fun()
local function guarded(entry, fn)
  entry.busy = true
  local ok, err = pcall(fn)
  entry.busy = false
  if not ok then
    vim.notify_once("deckle: scroll sync failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

--- Linha de tela do cursor de `win` dentro dela, 0-indexada.
---@param win integer
---@return integer
local function screen_row(win)
  local ok, row = pcall(vim.api.nvim_win_call, win, vim.fn.winline)
  return ok and row - 1 or 0
end

--- Leva o cursor de `win` para a linha `line` (0-indexada) e rola a janela para que ela fique
--- na linha de tela `row`. A coluna é a que o cursor já tinha (o Neovim a ajusta ao tamanho da
--- linha nova). Devolve a linha de fato usada, já dentro do buffer.
---@param win integer
---@param line integer
---@param row integer
---@return integer
local function place(win, line, row)
  local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  line = math.max(0, math.min(line, count - 1))
  local height = vim.api.nvim_win_get_height(win)
  row = math.max(0, math.min(row, height - 1))
  -- Sem deixar o fim do buffer com um vão embaixo: a última página cheia é o limite.
  local topline = math.max(1, math.min(line + 1 - row, count - height + 1))
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ lnum = line + 1, topline = topline })
  end)
  return line
end

--- Janela do fonte a que um movimento do preview se aplica: a última em que o cursor andou, e
--- na falta dela uma que mostre o buffer, de preferência na aba atual.
---@param entry deckle.SyncEntry
---@return integer|nil
local function source_window(entry)
  local win = entry.src_win
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == entry.src then
    return win
  end
  local current = vim.api.nvim_get_current_tabpage()
  local found = vim.fn.win_findbuf(entry.src)
  for _, candidate in ipairs(found) do
    if vim.api.nvim_win_get_tabpage(candidate) == current then
      entry.src_win = candidate
      return candidate
    end
  end
  entry.src_win = found[1]
  return found[1]
end

---@param entry deckle.SyncEntry
---@return boolean
local function preview_alive(entry)
  return vim.api.nvim_win_is_valid(entry.win)
    and vim.api.nvim_buf_is_valid(entry.buf)
    and vim.api.nvim_win_get_buf(entry.win) == entry.buf
end

--- Leva o outro lado para onde o cursor de `win` (do lado `side`, na linha `line`) está.
--- Chamar dentro de `guarded`.
---@param entry deckle.SyncEntry
---@param side deckle.SyncSide
---@param win integer
---@param line integer
local function follow(entry, side, win, line)
  if side == "src" then
    local target = M.src_to_preview(entry.map, line)
    if target and preview_alive(entry) then
      entry.expect.preview = place(entry.win, target, screen_row(win))
    end
  else
    local target = M.preview_to_src(entry.map, line)
    local dst = source_window(entry)
    if target and dst then
      entry.expect.src = place(dst, target, screen_row(win))
    end
  end
end

--- `CursorMoved` num dos dois buffers.
---@param entry deckle.SyncEntry
---@param side deckle.SyncSide
local function on_moved(entry, side)
  if entry.busy or entries[entry.src] ~= entry then
    return
  end
  -- O evento vale para a janela atual, e só se ela mostra o buffer do lado.
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= (side == "src" and entry.src or entry.buf) then
    return
  end
  local line = vim.api.nvim_win_get_cursor(win)[1] - 1
  if side == "src" then
    entry.src_win = win
  end

  -- O cursor está onde o próprio módulo o pôs: o evento é o atraso de uma janela que só agora
  -- virou a atual, não um movimento do usuário.
  local expected = entry.expect[side]
  entry.expect[side] = nil
  if expected == line then
    return
  end

  guarded(entry, function()
    follow(entry, side, win, line)
  end)
end

--- `User DeckleRender`: o mapa mudou.
---@param entry deckle.SyncEntry
---@param data table|nil
local function on_render(entry, data)
  if entries[entry.src] ~= entry or not data or data.src_buf ~= entry.src then
    return
  end
  local state = require("deckle.preview").state(entry.src)
  entry.map = state and state.map or {}

  local first = not entry.rendered
  entry.rendered = true

  local current = vim.api.nvim_get_current_win()
  local win
  if vim.api.nvim_win_get_buf(current) == entry.src then
    win = current
    entry.src_win = current
  elseif first then
    -- Primeiro render com o foco fora do fonte (`split = "tab"` abre o preview numa aba nova).
    win = source_window(entry)
  end
  if not win then
    return
  end
  guarded(entry, function()
    follow(entry, "src", win, vim.api.nvim_win_get_cursor(win)[1] - 1)
  end)
end

--- Liga a sincronia do preview aberto de `src`. Sem efeito, e sem criar autocmd nenhum, com
--- `sync = "off"` ou sem preview aberto. Chamar de novo refaz tudo do zero.
---@param src integer
---@return boolean attached
function M.attach(src)
  M.detach(src)
  if config().sync ~= "cursor" then
    return false
  end
  local state = require("deckle.preview").state(src)
  if not state or not state.win then
    return false
  end

  ---@type deckle.SyncEntry
  local entry = {
    src = src,
    buf = state.buf,
    win = state.win,
    group = vim.api.nvim_create_augroup(("deckle_sync_%d"):format(src), { clear = true }),
    map = state.map,
    busy = false,
    expect = {},
    rendered = false,
  }
  entries[src] = entry

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = entry.group,
    buffer = src,
    desc = "deckle: move the preview to the block under the source cursor",
    callback = function()
      on_moved(entry, "src")
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = entry.group,
    buffer = entry.buf,
    desc = "deckle: move the source cursor to the block under the preview cursor",
    callback = function()
      on_moved(entry, "preview")
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = entry.group,
    pattern = "DeckleRender",
    desc = "deckle: reread the preview map after a render",
    callback = function(args)
      on_render(entry, args.data)
    end,
  })
  return true
end

--- Desliga a sincronia de `src` e remove os autocmds dela. Idempotente.
---@param src integer
function M.detach(src)
  local entry = entries[src]
  if not entry then
    return
  end
  entries[src] = nil
  pcall(vim.api.nvim_del_augroup_by_id, entry.group)
end

--- Verdadeiro se `src` tem a sincronia ligada.
---@param src integer
---@return boolean
function M.is_attached(src)
  return entries[src] ~= nil
end

return M
