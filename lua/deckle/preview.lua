--- Buffer de preview, janela e re-render (fase 2).
---
--- Cada buffer fonte tem no máximo um preview, guardado em `states[src_buf]`. O buffer de
--- preview é scratch e `nomodifiable`, e **só ele** recebe texto e extmarks: o fonte não ganha
--- extmark, opção nem parser (ADR-0003). O único vestígio no fonte são autocmds de buffer, e
--- eles não alteram o conteúdo nem a aparência dele.
---
--- # Ciclo de vida
---
--- * `open`: cria o buffer na primeira vez e o reaproveita nas seguintes, abre a janela,
---   registra os autocmds vivos (e liga `deckle.sync`, que tem os dele) e renderiza.
--- * `close`: fecha a janela e remove os autocmds vivos, os de `deckle.sync` inclusive. O buffer
---   fica, escondido, para a próxima abertura. Sobra só o autocmd que descarta o estado
---   (abaixo).
--- * Fonte ou preview apagado (`BufDelete`, `BufWipeout`): descarta tudo, inclusive o buffer
---   de preview. Sem isso o preview escondido vazaria junto com cada fonte fechado.
---
--- # Eventos `User`
---
--- Para quem precisa reagir ao preview sem editar este módulo (a sincronia de scroll da fase
--- 3, em especial), `data = { src_buf, buf, win }` em todos:
---
--- * `DeckleOpen`: a janela existe e o primeiro render ainda não aconteceu;
--- * `DeckleRender`: depois de cada render, com `state(src_buf).map` já novo;
--- * `DeckleClose`: a janela foi fechada (`win` é `nil`).

local M = {}

--- Namespace dos extmarks do preview. Só o buffer de preview tem marcas nele.
M.ns = vim.api.nvim_create_namespace("deckle.preview")

---@class deckle.PreviewState
---@field src integer                  buffer fonte
---@field buf integer                  buffer de preview
---@field win integer|nil              janela de preview; `nil` com o preview fechado
---@field live integer|nil             augroup dos autocmds vivos (só com a janela aberta)
---@field dispose integer              augroup do descarte
---@field timer uv.uv_timer_t|nil
---@field map deckle.MapEntry[]        mapa do último render
---@field width integer|nil            largura do último render
---@field renders integer              quantos renders já aconteceram

---@type table<integer, deckle.PreviewState>
local states = {}

---@param msg string
---@param level integer|nil
local function notify(msg, level)
  vim.notify("deckle: " .. msg, level or vim.log.levels.INFO)
end

---@return table
local function config()
  return require("deckle.config").options
end

---@param name string
---@param st deckle.PreviewState
local function emit(name, st)
  vim.api.nvim_exec_autocmds("User", {
    pattern = name,
    modeline = false,
    data = { src_buf = st.src, buf = st.buf, win = st.win },
  })
end

--- Buffer fonte a que `bufnr` se refere: ele mesmo, ou, se for um preview, o fonte dele.
---@param bufnr integer|nil `nil` ou `0` é o buffer atual
---@return integer
local function resolve_src(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  for src, st in pairs(states) do
    if st.buf == bufnr then
      return src
    end
  end
  return bufnr
end

---@param st deckle.PreviewState
---@return boolean
local function window_open(st)
  return st.win ~= nil and vim.api.nvim_win_is_valid(st.win)
end

-- ---------------------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------------------

---@param st deckle.PreviewState
---@return integer
local function render_width(st)
  return config().width or vim.api.nvim_win_get_width(st.win)
end

--- Troca o conteúdo do buffer de preview e refaz as marcas. Preserva a posição da janela: o
--- re-render de quem está lendo no meio do documento não pode devolvê-lo ao topo.
---@param st deckle.PreviewState
---@param result deckle.RenderResult
local function write(st, result)
  local buf, win = st.buf, st.win
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)

  vim.bo[buf].modifiable = true
  local ok, err = pcall(function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    for _, mark in ipairs(result.marks) do
      -- Uma marca ruim (módulo de render com bug) não pode derrubar as outras.
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, mark.row, mark.col, {
        end_col = mark.end_col,
        hl_group = mark.hl,
        priority = mark.priority,
        strict = false,
      })
    end
  end)
  vim.bo[buf].modifiable = false

  vim.api.nvim_win_call(win, function()
    pcall(vim.fn.winrestview, view)
  end)
  if not ok then
    error(err, 0)
  end
end

---@param st deckle.PreviewState
local function stop_timer(st)
  if st.timer then
    st.timer:stop()
    st.timer:close()
    st.timer = nil
  end
end

--- Render síncrono. Sem janela aberta não há largura nem para quem mostrar: não faz nada.
---@param st deckle.PreviewState
local function render(st)
  if not window_open(st) or not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  local width = render_width(st)
  local ok, err = pcall(function()
    local ir = require("deckle.parse").parse(st.src)
    local result = require("deckle.render").render(ir, {
      width = width,
      charset = config().charset,
    })
    write(st, result)
    st.map = result.map
  end)
  if not ok then
    notify("render failed: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  st.width = width
  st.renders = st.renders + 1
  emit("DeckleRender", st)
end

--- Agenda um render para daqui a `debounce_ms`. Chamadas dentro da janela se fundem em uma:
--- digitar não pode custar um parse por tecla.
---@param st deckle.PreviewState
local function schedule(st)
  if not st.timer then
    st.timer = vim.uv.new_timer()
  end
  st.timer:stop()
  st.timer:start(
    config().debounce_ms,
    0,
    vim.schedule_wrap(function()
      if states[st.src] == st then
        render(st)
      end
    end)
  )
end

-- ---------------------------------------------------------------------------------------
-- Autocmds
-- ---------------------------------------------------------------------------------------

--- Remove os autocmds vivos e o timer. Não mexe na janela.
---@param st deckle.PreviewState
local function detach(st)
  stop_timer(st)
  require("deckle.sync").detach(st.src)
  if st.live then
    pcall(vim.api.nvim_del_augroup_by_id, st.live)
    st.live = nil
  end
end

---@param st deckle.PreviewState
local function attach(st)
  local group = vim.api.nvim_create_augroup(("deckle_preview_%d"):format(st.src), { clear = true })
  st.live = group

  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    buffer = st.src,
    desc = "deckle: re-render the preview after the source changed",
    callback = function()
      schedule(st)
    end,
  })

  -- `WinResized` também dispara por mudança de altura, e `render` não muda tamanho nenhum:
  -- só vale o trabalho se a largura mudou de fato.
  local function on_resize()
    if window_open(st) and render_width(st) ~= st.width then
      schedule(st)
    end
  end
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    desc = "deckle: re-render the preview after a resize",
    callback = on_resize,
  })

  -- O usuário fechou a janela por conta própria (`:q`, `<C-w>c`).
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(st.win),
    desc = "deckle: forget the preview window once it is closed",
    callback = function()
      if st.win then
        st.win = nil
        detach(st)
        emit("DeckleClose", st)
      end
    end,
  })

  -- Sincronia de scroll (fase 3): sem autocmd nenhum com `sync = "off"`.
  require("deckle.sync").attach(st.src)
end

--- Descarta o estado de um preview: autocmds, timer, janela e buffer. Idempotente, porque o
--- próprio `nvim_buf_delete` dispara `BufWipeout` de volta aqui.
---
--- `from_preview` diz que quem chamou foi um evento do próprio buffer de preview (apagado à
--- mão): apagá-lo de dentro do evento dele dá E937, então a limpeza fica para a próxima volta
--- do laço. `:bwipeout` já o apagou, e `:bdelete` o deixaria descarregado e escondido.
---@param src integer
---@param from_preview boolean|nil
local function dispose(src, from_preview)
  local st = states[src]
  if not st then
    return
  end
  states[src] = nil

  local was_open = window_open(st)
  detach(st)
  pcall(vim.api.nvim_del_augroup_by_id, st.dispose)
  if was_open then
    pcall(vim.api.nvim_win_close, st.win, true)
  end
  st.win = nil

  local buf = st.buf
  local function wipe()
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if from_preview then
    vim.schedule(wipe)
  else
    wipe()
  end
  if was_open then
    emit("DeckleClose", st)
  end
end

-- ---------------------------------------------------------------------------------------
-- Buffer e janela
-- ---------------------------------------------------------------------------------------

---@param src integer
---@return deckle.PreviewState
local function create_state(src)
  local buf = vim.api.nvim_create_buf(false, true) -- não listado, scratch
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1 -- cada render troca o buffer inteiro: sem histórico de undo
  vim.bo[buf].filetype = "deckle"
  vim.bo[buf].modifiable = false

  -- Nome só para a statusline e `:ls!`. Dois fontes de mesmo nome colidem (E95): o segundo
  -- leva o número do buffer.
  local tail = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(src), ":t")
  if tail == "" then
    tail = "[No Name]"
  end
  if not pcall(vim.api.nvim_buf_set_name, buf, "deckle://" .. tail) then
    pcall(vim.api.nvim_buf_set_name, buf, ("deckle://%d/%s"):format(src, tail))
  end

  ---@type deckle.PreviewState
  local st = {
    src = src,
    buf = buf,
    dispose = vim.api.nvim_create_augroup(("deckle_dispose_%d"):format(src), { clear = true }),
    map = {},
    renders = 0,
  }
  states[src] = st

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = st.dispose,
    buffer = src,
    desc = "deckle: drop the preview when its source buffer goes away",
    callback = function()
      dispose(src)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = st.dispose,
    buffer = buf,
    desc = "deckle: forget a preview buffer that was deleted by hand",
    callback = function()
      dispose(src, true)
    end,
  })
  return st
end

---@param win integer
local function set_window_options(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.list = false
  wo.spell = false
  wo.conceallevel = 0
  wo.colorcolumn = ""
  -- O texto já vem quebrado na largura da janela. O que passa dela (código, diagrama) é
  -- para rolar na horizontal, não para ser partido ao meio.
  wo.wrap = false
end

---@param st deckle.PreviewState
---@return integer win
local function open_window(st)
  local split = config().split
  local win
  if split == "tab" then
    vim.cmd(("tab sbuffer %d"):format(st.buf))
    win = vim.api.nvim_get_current_win()
  else
    local anchor = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(anchor) ~= st.src then
      local found = vim.fn.bufwinid(st.src)
      if found ~= -1 then
        anchor = found
      end
    end
    win = vim.api.nvim_open_win(st.buf, false, {
      split = split == "split" and "below" or "right",
      win = anchor,
    })
    local width = config().width
    if width and split == "vsplit" then
      vim.api.nvim_win_set_width(win, width)
    end
  end
  set_window_options(win)
  return win
end

-- ---------------------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------------------

--- Abre o preview do buffer `bufnr` (default: o atual). Já aberto, só renderiza de novo e leva
--- o foco para ele. Dentro de um buffer de preview, vale o fonte dele.
---@param bufnr integer|nil
function M.open(bufnr)
  local src = resolve_src(bufnr)
  if not vim.api.nvim_buf_is_valid(src) then
    notify(("buffer %d is not valid"):format(src), vim.log.levels.ERROR)
    return
  end

  local st = states[src] or create_state(src)
  if window_open(st) then
    vim.api.nvim_set_current_win(st.win)
    stop_timer(st)
    render(st)
    return
  end

  require("deckle.highlight").setup()
  local ok, win = pcall(open_window, st)
  if not ok then
    notify("could not open the preview window: " .. tostring(win), vim.log.levels.ERROR)
    return
  end
  st.win = win
  attach(st)
  emit("DeckleOpen", st)
  render(st)
end

--- Fecha a janela do preview. O buffer fica, escondido, para a próxima abertura.
---@param bufnr integer|nil
function M.close(bufnr)
  local st = states[resolve_src(bufnr)]
  if not st or not window_open(st) then
    notify("there is no open preview for this buffer")
    return
  end
  local win = st.win
  st.win = nil
  detach(st)
  pcall(vim.api.nvim_win_close, win, true)
  emit("DeckleClose", st)
end

--- Abre o preview se estiver fechado e fecha se estiver aberto.
---@param bufnr integer|nil
function M.toggle(bufnr)
  local st = states[resolve_src(bufnr)]
  if st and window_open(st) then
    M.close(bufnr)
  else
    M.open(bufnr)
  end
end

--- Renderiza de novo agora, sem esperar o debounce.
---@param bufnr integer|nil
function M.refresh(bufnr)
  local st = states[resolve_src(bufnr)]
  if not st or not window_open(st) then
    notify("there is no open preview for this buffer")
    return
  end
  stop_timer(st)
  render(st)
end

--- Retrato do preview de um buffer fonte, ou `nil` se ele nunca foi aberto (ou já foi
--- descartado). É uma cópia rasa: `map` é a tabela do último render e não deve ser alterada.
---
--- * `src_buf`, `buf`: o fonte e o buffer de preview;
--- * `win`: a janela do preview, `nil` com ele fechado;
--- * `map`: `deckle.MapEntry[]` do último render (ver `deckle.render`);
--- * `width`: a largura desse render;
--- * `renders`: quantos renders já aconteceram.
---@param src_buf integer
---@return { src_buf: integer, buf: integer, win: integer|nil, map: deckle.MapEntry[], width: integer|nil, renders: integer }|nil
function M.state(src_buf)
  local st = states[src_buf]
  if not st then
    return nil
  end
  return {
    src_buf = st.src,
    buf = st.buf,
    win = window_open(st) and st.win or nil,
    map = st.map,
    width = st.width,
    renders = st.renders,
  }
end

return M
