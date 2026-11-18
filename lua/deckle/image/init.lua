--- Imagens no preview, camada 2 (fase 9).
---
--- Um parágrafo que é só `![alt](caminho.png)` vira uma imagem de verdade quando o terminal fala o
--- protocolo gráfico do kitty (`deckle.caps`), e continua sendo o texto `[image: alt]` em todo
--- outro caso. Este módulo é o lado com estado: acha o arquivo, mede o PNG, reserva as linhas,
--- aloca o id, escreve no terminal e, ao fechar o preview, apaga tudo o que escreveu.
---
--- # Abordagem: Unicode placeholders
---
--- A imagem é transmitida uma vez e o texto do preview ganha, onde ela deve aparecer, células
--- `U+10EEEE` coloridas com o id dela (ver `deckle.image.kitty`). Como o placeholder é texto, o
--- Neovim o rola e o redesenha junto com o buffer, e a sincronia de scroll da fase 3 não sabe
--- que ali tem uma imagem: o bloco é um bloco do mapa como outro qualquer, com N linhas. Nada de
--- reposicionar a imagem a cada `WinScrolled`, que era a parte difícil.
---
--- O custo está em outro lugar: o id é a **cor** do primeiro plano, então cabe em um byte (ids de
--- 16 a 255: 240 imagens por vez) e cada id ganha um grupo de highlight próprio (`DeckleImg<id>`), que o
--- `CursorLine` ou outro highlight com `fg` por cima pode estragar. O tamanho de uma célula em
--- pixels não está na API do Neovim: o deckle supõe `CELL_W` x `CELL_H` para escolher quantas
--- linhas reservar, e o kitty encaixa a imagem no retângulo mantendo a proporção. Se a suposição
--- errar, sobra margem, não distorção.
---
--- # O que vira imagem
---
--- Só PNG local: o caminho é relativo ao arquivo fonte (ou absoluto, ou `~/`), com `%20` e afins
--- decodificados. URL remota, `data:`, JPEG, SVG, arquivo ausente, ilegível, grande demais ou com
--- cabeçalho que não é de PNG viram texto alternativo, sem erro. O mesmo vale para uma imagem no
--- meio de um texto, dentro de um link ou ao lado de outra imagem: só o parágrafo de uma imagem
--- sozinha é reservado como bloco.
---
--- # Fluxo
---
--- ```lua
--- local session = require("deckle.image").session(src_buf)  -- nil sem protocolo gráfico
--- local result = require("deckle.render").render(ir, { images = session, ... })
--- -- ... escreve o buffer ...
--- session.commit()   -- transmite o que é novo, apaga o que sumiu
--- ```
---
--- O render só chama `session.lookup(src, width)`, que devolve `{ id, cols, rows, hl }` ou `nil`
--- (e então o bloco cai no texto alternativo). Nada é escrito no terminal antes do `commit`, e
--- o `commit` só envia o que mudou: o id de uma imagem é estável entre renders enquanto o arquivo
--- e o tamanho dela não mudarem, então digitar no fonte não retransmite nada.
---
--- # Terminal
---
--- Toda escrita passa por **uma** função, `writer`, trocável com `set_writer`: é por ela que os
--- testes capturam os bytes sem terminal. O padrão escreve em `vim.v.stderr`, que no Neovim com
--- TUI é o tty do terminal (o stdout é o canal RPC com a interface), e **só** se houver uma
--- interface de terminal ligada: sem TUI (`--headless`, os testes) não escreve em lugar nenhum.
--- Dentro do tmux cada escape sai embrulhado para o repasse; numa sessão remota (SSH, com
--- `images.enabled = true`) a imagem vai inteira pelo tty em vez de por caminho.
---
--- Fechar o preview (`clear`) apaga cada imagem com `d=I`, que também libera a memória no
--- terminal, e uma rede de segurança em `VimLeavePre` apaga o que sobrou.

local caps = require("deckle.caps")
local kitty = require("deckle.image.kitty")
local png = require("deckle.image.png")

local M = {}

--- Tamanho suposto de uma célula do terminal, em pixels. Não há como perguntar ao Neovim.
M.CELL_W = 10
M.CELL_H = 20

--- Maior PNG aceito por caminho e pelos próprios bytes (esse viaja inteiro pelo tty).
M.MAX_FILE_BYTES = 32 * 1024 * 1024
M.MAX_DIRECT_BYTES = 4 * 1024 * 1024

---@class deckle.ImageHandle
---@field id integer     id do kitty (também a cor do placeholder)
---@field cols integer
---@field rows integer
---@field hl string      grupo de highlight que carrega o id na cor

---@class deckle.ImageSession
---@field lookup fun(src: string, width: integer): deckle.ImageHandle|nil
---@field commit fun()

---@class deckle.ImageSpec
---@field path string
---@field cols integer
---@field rows integer
---@field key string
---@field sent boolean

---@class deckle.ImageState
---@field by_key table<string, integer>
---@field spec table<integer, deckle.ImageSpec>

-- ---------------------------------------------------------------------------------------
-- Escrita no terminal
-- ---------------------------------------------------------------------------------------

---@param data string
---@return boolean written
local function default_writer(data)
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.stdout_tty then
      vim.api.nvim_chan_send(vim.v.stderr, data)
      return true
    end
  end
  return false
end

---@type fun(data: string): any
local writer = default_writer

--- Troca a função que escreve no terminal (recebe os bytes de uma vez). `nil` volta ao padrão.
--- Existe para os testes: nada neste módulo escreve no tty por outro caminho.
---@param fn (fun(data: string): any)|nil
function M.set_writer(fn)
  writer = fn or default_writer
end

---@return table
local function options()
  return require("deckle.config").options.images
end

---@return deckle.Caps
local function active_caps()
  return caps.current({ optin = options().enabled == true })
end

--- Escreve os escapes, embrulhados para o tmux quando preciso. Um erro do `writer` vira aviso,
--- uma vez: o preview não pode quebrar porque o terminal não aceitou os bytes.
---@param seqs string[]
local function send(seqs)
  if #seqs == 0 then
    return
  end
  if active_caps().multiplexer == "tmux" then
    for i, seq in ipairs(seqs) do
      seqs[i] = kitty.tmux_wrap(seq)
    end
  end
  local ok, err = pcall(writer, table.concat(seqs))
  if not ok then
    vim.notify_once(
      "deckle: could not write the image to the terminal: " .. tostring(err),
      vim.log.levels.WARN
    )
  end
end

-- ---------------------------------------------------------------------------------------
-- Estado
-- ---------------------------------------------------------------------------------------

---@type table<integer, deckle.ImageState>
local states = {}

--- Ids em uso, de todos os previews: o espaço de ids é do terminal, não de um buffer.
---@type table<integer, true>
local taken = {}
local last_id = kitty.MIN_ID - 1

---@return integer|nil
local function allocate()
  local span = kitty.MAX_ID - kitty.MIN_ID + 1
  for _ = 1, span do
    -- Gira em vez de reusar o menor livre: um id acabado de apagar não volta já.
    last_id = (last_id - kitty.MIN_ID + 1) % span + kitty.MIN_ID
    if not taken[last_id] then
      taken[last_id] = true
      return last_id
    end
  end
  return nil
end

---@param id integer
---@return string
local function hl_name(id)
  return ("DeckleImg%d"):format(id)
end

--- O id vai na cor: `fg` para cor verdadeira (0x0000NN), `ctermfg` para 256 cores.
---@param id integer
local function define_hl(id)
  vim.api.nvim_set_hl(0, hl_name(id), { fg = id, ctermfg = id })
end

local hooked = false

--- Registra, na primeira escrita, os dois autocmds globais: apagar tudo ao sair e redefinir os
--- grupos de cor depois de um `:colorscheme` (que os limpa).
local function ensure_hooks()
  if hooked then
    return
  end
  hooked = true
  local group = vim.api.nvim_create_augroup("deckle_image", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    desc = "deckle: delete the images from the terminal on exit",
    callback = function()
      M.clear_all()
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "deckle: redefine the image highlight groups after a colorscheme change",
    callback = function()
      for id in pairs(taken) do
        define_hl(id)
      end
    end,
  })
end

---@param spec table<integer, deckle.ImageSpec>
---@return integer[]
local function sorted_ids(spec)
  local ids = vim.tbl_keys(spec)
  table.sort(ids)
  return ids
end

-- ---------------------------------------------------------------------------------------
-- Decisão: há imagem de verdade?
-- ---------------------------------------------------------------------------------------

--- Se o preview pode desenhar imagem, e por quê.
---
--- * `protocol`: `"kitty"` ou `nil`. É o que o deckle sabe desenhar, não o que o terminal fala:
---   iTerm2 e sixel são detectados (`caps.graphics`) e ficam em texto alternativo.
--- * `reason`: uma linha, para o `:checkhealth`.
--- * `caps`: a detecção, quando chegou a rodar (`images.enabled = false` não roda).
---@return { protocol: "kitty"|nil, reason: string, caps: deckle.Caps|nil }
function M.status()
  local enabled = options().enabled
  if enabled == false then
    return { reason = "disabled by `images.enabled = false`" }
  end
  local detected = active_caps()
  if detected.graphics == nil then
    return { reason = detected.reason, caps = detected }
  end
  if detected.graphics ~= "kitty" then
    return {
      reason = ("%s protocol detected (%s), which is not supported yet"):format(
        detected.graphics,
        detected.reason
      ),
      caps = detected,
    }
  end
  if vim.o.ambiwidth == "double" then
    -- O placeholder é um caractere de uso privado, que `ambiwidth=double` mede com duas células.
    return {
      reason = "`ambiwidth=double` would make the image cells two columns wide",
      caps = detected,
    }
  end
  return { protocol = "kitty", reason = detected.reason, caps = detected }
end

-- ---------------------------------------------------------------------------------------
-- Arquivo e tamanho
-- ---------------------------------------------------------------------------------------

--- Caminho local de uma referência de imagem do Markdown, ou `nil` se ela não é um arquivo local
--- (URL, `data:`) ou não dá para resolver (fonte sem nome e caminho relativo).
---@param src_buf integer
---@param ref string
---@return string|nil
local function local_path(src_buf, ref)
  -- Um esquema (`https:`, `data:`, `file:`) tem pelo menos duas letras; `C:\` é unidade do Windows.
  if ref == "" or ref:find("^%a[%w+.-]+:") or ref:find("^//") then
    return nil
  end
  ref = ref:gsub("[?#].*$", "")
  ref = ref:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  if ref == "" or ref:find("\0", 1, true) then
    return nil
  end
  if not (ref:find("^[/~]") or ref:find("^%a:[/\\]")) then
    local name = vim.api.nvim_buf_get_name(src_buf)
    if name == "" then
      return nil
    end
    ref = vim.fs.joinpath(vim.fn.fnamemodify(name, ":p:h"), ref)
  end
  return vim.fs.normalize(ref, { expand_env = false })
end

--- Quantas colunas e linhas reservar para um PNG de `w` x `h` pixels em `avail` colunas: o
--- tamanho natural (na célula suposta), limitado pela largura e por `images.max_height`.
---@param w integer
---@param h integer
---@param avail integer
---@return integer cols, integer rows
local function fit(w, h, avail)
  local max_rows = math.min(options().max_height, kitty.MAX_CELLS)
  local cols = math.max(1, math.min(avail, math.ceil(w / M.CELL_W), kitty.MAX_CELLS))
  local rows = math.max(1, math.ceil(cols * M.CELL_W * h / (w * M.CELL_H)))
  if rows > max_rows then
    rows = max_rows
    cols = math.max(1, math.min(cols, math.floor(rows * M.CELL_H * w / (h * M.CELL_W))))
  end
  return cols, rows
end

---@param path string
---@return string|nil
local function read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

-- ---------------------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------------------

--- Abre uma sessão de render para o preview de `src`. `nil` quando não há protocolo gráfico
--- (`status`): o render segue sem imagens e o resultado é o da camada 0. Nesse caso, o que um
--- render anterior tenha transmitido é apagado.
---@param src integer buffer fonte
---@return deckle.ImageSession|nil
function M.session(src)
  local status = M.status()
  if not status.protocol then
    M.clear(src)
    return nil
  end

  local st = states[src]
  if not st then
    st = { by_key = {}, spec = {} }
    states[src] = st
  end
  local remote = status.caps ~= nil and status.caps.remote
  local used = {} ---@type table<integer, true>

  ---@type deckle.ImageSession
  local session = {}

  function session.lookup(ref, avail)
    local path = local_path(src, ref or "")
    local stat = path and vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
      return nil
    end
    if stat.size > (remote and M.MAX_DIRECT_BYTES or M.MAX_FILE_BYTES) then
      return nil
    end
    local w, h = png.size(path)
    if not w then
      return nil
    end

    local cols, rows = fit(w, h, avail)
    local key = table.concat({
      path,
      stat.size,
      stat.mtime.sec,
      stat.mtime.nsec,
      cols,
      rows,
    }, "\0")
    local id = st.by_key[key]
    if not id then
      id = allocate()
      if not id then
        return nil -- os 240 ids estão em uso: o resto cai no texto alternativo
      end
      st.by_key[key] = id
      st.spec[id] = { path = path, cols = cols, rows = rows, key = key, sent = false }
    end
    used[id] = true
    define_hl(id)
    return { id = id, cols = cols, rows = rows, hl = hl_name(id) }
  end

  function session.commit()
    if states[src] ~= st then
      return -- o preview foi fechado no meio do render
    end
    local ok, err = pcall(function()
      local seqs = {}
      for _, id in ipairs(sorted_ids(st.spec)) do
        local spec = st.spec[id]
        if used[id] then
          if not spec.sent then
            local transmit
            if remote then
              local data = read_file(spec.path)
              transmit = data and kitty.transmit_data(id, data)
            else
              transmit = kitty.transmit_file(id, spec.path)
            end
            -- Arquivo que sumiu entre o `lookup` e o `commit`: fica sem imagem, e o próximo
            -- render tenta de novo.
            if transmit then
              vim.list_extend(seqs, transmit)
              vim.list_extend(seqs, kitty.place(id, spec.cols, spec.rows))
              spec.sent = true
            end
          end
        else
          -- A imagem saiu do documento (ou mudou de tamanho e ganhou outro id).
          if spec.sent then
            vim.list_extend(seqs, kitty.delete(id))
          end
          st.by_key[spec.key] = nil
          st.spec[id] = nil
          taken[id] = nil
        end
      end
      if #seqs > 0 then
        ensure_hooks()
        send(seqs)
      end
    end)
    if not ok then
      vim.notify_once("deckle: could not update the images: " .. tostring(err), vim.log.levels.WARN)
    end
  end

  return session
end

--- Apaga do terminal todas as imagens de `src` e esquece os ids. Idempotente. É o que fechar o
--- preview chama.
---@param src integer
function M.clear(src)
  local st = states[src]
  if not st then
    return
  end
  states[src] = nil
  local seqs = {}
  for _, id in ipairs(sorted_ids(st.spec)) do
    if st.spec[id].sent then
      vim.list_extend(seqs, kitty.delete(id))
    end
    taken[id] = nil
  end
  send(seqs)
end

--- `clear` em todos os previews.
function M.clear_all()
  for _, src in ipairs(vim.tbl_keys(states)) do
    M.clear(src)
  end
end

--- Marca as imagens de `src` como não transmitidas: o próximo `commit` as envia de novo, com os
--- mesmos ids. É o `:Deckle refresh`, para quando o terminal perdeu as imagens (um reset, por
--- exemplo).
---@param src integer
function M.reset(src)
  local st = states[src]
  if not st then
    return
  end
  for _, spec in pairs(st.spec) do
    spec.sent = false
  end
end

--- Retrato das imagens de `src` (para teste e depuração), ordenado por id.
---@param src integer
---@return { id: integer, path: string, cols: integer, rows: integer, sent: boolean }[]
function M.placements(src)
  local st = states[src]
  local out = {}
  if not st then
    return out
  end
  for _, id in ipairs(sorted_ids(st.spec)) do
    local spec = st.spec[id]
    out[#out + 1] =
      { id = id, path = spec.path, cols = spec.cols, rows = spec.rows, sent = spec.sent }
  end
  return out
end

return M
