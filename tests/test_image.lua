-- Testes das imagens da fase 9: os bytes do protocolo, a leitura do PNG, o provedor de imagens
-- (`deckle.image`) e o gancho do render (`render/image.lua`).
--
-- Nada aqui escreve no terminal: o `writer` é trocado por um que junta os bytes numa tabela
-- (`set_writer`), e a detecção de capacidade é forjada (`caps.set_override`). Os gates da fase
-- que dependem de uma janela de preview (fechar apaga as imagens; sem protocolo o preview é
-- idêntico ao da camada 0) estão em `tests/test_preview_images.lua`.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h")
local fixture = dofile(tests_dir .. "/png_fixture.lua")

local caps = require("deckle.caps")
local image = require("deckle.image")
local kitty = require("deckle.image.kitty")
local png = require("deckle.image.png")
local parse = require("deckle.parse")
local render = require("deckle.render")

local ESC = "\27"
local KITTY_ENV = { TERM = "xterm-kitty", KITTY_WINDOW_ID = "1" }

---@return table
local function config()
  return require("deckle.config")
end

local function b64(data)
  return vim.base64.encode(data)
end

local function cp(n)
  return vim.fn.nr2char(n)
end

-- ---------------------------------------------------------------------------------------
-- Estado de cada caso: um diretório, um buffer fonte dentro dele e um writer que captura
-- ---------------------------------------------------------------------------------------

---@type { dir: string, src: integer, written: string[], saved: table, notes: table[], notify: function }
local ctx = {}

local T = new_set({
  hooks = {
    pre_case = function()
      ctx.dir = vim.fn.tempname()
      vim.fn.mkdir(ctx.dir, "p")
      ctx.src = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(ctx.src, ctx.dir .. "/doc.md")

      ctx.written = {}
      image.set_writer(function(data)
        ctx.written[#ctx.written + 1] = data
      end)
      caps.set_override(KITTY_ENV)

      ctx.saved = vim.deepcopy(config().options.images)
      config().options.images = { enabled = "auto", max_height = 20 }

      ctx.notes = {}
      ctx.notify = vim.notify
      vim.notify = function(msg, level)
        ctx.notes[#ctx.notes + 1] = { msg = msg, level = level }
      end
    end,
    post_case = function()
      vim.notify = ctx.notify
      image.clear_all()
      image.set_writer(nil)
      caps.set_override(nil)
      config().options.images = ctx.saved
      pcall(vim.api.nvim_buf_delete, ctx.src, { force = true })
      vim.fn.delete(ctx.dir, "rf")
    end,
  },
})

--- Tudo o que o writer recebeu, como um texto só.
---@return string
local function written()
  return table.concat(ctx.written)
end

---@param name string
---@param w integer
---@param h integer
---@return string path
local function put_png(name, w, h)
  local path = ctx.dir .. "/" .. name
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  fixture.write(path, w, h)
  return path
end

-- ---------------------------------------------------------------------------------------
-- Bytes do protocolo (snapshot)
-- ---------------------------------------------------------------------------------------

T["protocolo"] = new_set()

T["protocolo"]["transmitir por caminho: `a=t,f=100,t=f` com o caminho em base64"] = function()
  eq(
    kitty.transmit_file(7, "/tmp/a.png"),
    { ESC .. "_Ga=t,f=100,t=f,i=7,q=2;L3RtcC9hLnBuZw==" .. ESC .. "\\" }
  )
end

T["protocolo"]["posicionamento virtual: `a=p,U=1` com colunas e linhas"] = function()
  eq(kitty.place(7, 12, 3), { ESC .. "_Ga=p,U=1,i=7,c=12,r=3,C=1,q=2" .. ESC .. "\\" })
end

T["protocolo"]["apagar: `a=d,d=I` só da imagem, nunca `d=a`"] = function()
  eq(kitty.delete(7), { ESC .. "_Ga=d,d=I,i=7,q=2" .. ESC .. "\\" })
  eq(kitty.delete(7)[1]:find("d=a", 1, true), nil)
end

T["protocolo"]["toda resposta do terminal é calada (`q=2`)"] = function()
  local all = {
    kitty.transmit_file(1, "/x.png"),
    kitty.transmit_data(1, "abc"),
    kitty.transmit_data(1, string.rep("x", 20000)),
    kitty.place(1, 2, 2),
    kitty.delete(1),
  }
  for _, escapes in ipairs(all) do
    for _, seq in ipairs(escapes) do
      eq(seq:find("q=2", 1, true) ~= nil, true)
    end
  end
end

T["protocolo"]["bytes pelo tty: um pedaço só, sem `m`"] = function()
  eq(kitty.transmit_data(3, "PNGDATA"), {
    ESC .. "_Ga=t,f=100,t=d,i=3,q=2;" .. b64("PNGDATA") .. ESC .. "\\",
  })
end

T["protocolo"]["bytes pelo tty: pedaços de até 4096, `m=1` até o penúltimo"] = function()
  local data = string.rep("x", 10000)
  local encoded = b64(data)
  local escapes = kitty.transmit_data(3, data)
  eq(#escapes, math.ceil(#encoded / 4096))
  eq(
    escapes[1]:sub(1, #(ESC .. "_Ga=t,f=100,t=d,i=3,q=2,m=1;")),
    ESC .. "_Ga=t,f=100,t=d,i=3,q=2,m=1;"
  )
  eq(vim.startswith(escapes[2], ESC .. "_Gm=1,q=2;"), true)
  eq(vim.startswith(escapes[#escapes], ESC .. "_Gm=0,q=2;"), true)

  local joined = {}
  for i, seq in ipairs(escapes) do
    local payload = seq:match(";(.*)" .. ESC .. "\\$")
    if i < #escapes then
      -- Todos menos o último têm tamanho múltiplo de 4: o protocolo exige.
      eq({ i, #payload }, { i, 4096 })
    end
    joined[#joined + 1] = payload
  end
  eq(table.concat(joined), encoded)
  eq(vim.base64.decode(table.concat(joined)), data)
end

T["protocolo"]["bytes pelo tty: só o primeiro escape leva a ação e o formato"] = function()
  local escapes = kitty.transmit_data(3, string.rep("y", 9000))
  for i = 2, #escapes do
    eq(escapes[i]:find("a=t", 1, true), nil)
    eq(escapes[i]:find("i=3", 1, true), nil)
  end
end

T["protocolo"]["tmux: embrulha em `DCS tmux;` e dobra cada ESC"] = function()
  local inner = kitty.delete(7)[1]
  eq(
    kitty.tmux_wrap(inner),
    ESC .. "Ptmux;" .. ESC .. ESC .. "_Ga=d,d=I,i=7,q=2" .. ESC .. ESC .. "\\" .. ESC .. "\\"
  )
end

T["protocolo"]["célula: `U+10EEEE` mais os diacríticos de linha e coluna"] = function()
  local ph = cp(0x10EEEE)
  eq(kitty.cell(0, 0), ph .. cp(0x0305) .. cp(0x0305))
  eq(kitty.cell(1, 0), ph .. cp(0x030D) .. cp(0x0305))
  eq(kitty.cell(0, 2), ph .. cp(0x0305) .. cp(0x030E))
end

T["protocolo"]["o 2x2 do exemplo da documentação do kitty"] = function()
  local ph = cp(0x10EEEE)
  local z, one = cp(0x0305), cp(0x030D)
  eq(kitty.placeholder_row(0, 2), ph .. z .. z .. ph .. z .. one)
  eq(kitty.placeholder_row(1, 2), ph .. one .. z .. ph .. one .. one)
end

T["protocolo"]["a tabela de diacríticos tem 297 entradas, crescentes, e é o que o kitty publica"] = function()
  local d = kitty.DIACRITICS
  eq(#d, 297)
  eq(kitty.MAX_CELLS, 297)
  eq(d[1], 0x0305)
  eq(d[2], 0x030D)
  eq(d[#d], 0x1D244)
  for i = 2, #d do
    eq(d[i] > d[i - 1], true)
  end
end

T["protocolo"]["uma linha de N colunas ocupa N células de largura, em UTF-8 de 4 bytes + 2 + 2"] = function()
  local row = kitty.placeholder_row(3, 25)
  eq(vim.fn.strdisplaywidth(row), 25)
  eq(vim.api.nvim_strwidth(row), 25)
  eq(#row, 25 * 8)
end

T["protocolo"]["fora da tabela de diacríticos é erro, não imagem torta"] = function()
  eq(pcall(kitty.cell, 0, 297), false)
  eq(pcall(kitty.cell, 296, 296), true)
end

-- ---------------------------------------------------------------------------------------
-- PNG
-- ---------------------------------------------------------------------------------------

T["png"] = new_set()

---@param name string
---@param data string
---@return string
local function put_raw(name, data)
  local path = ctx.dir .. "/" .. name
  fixture.write_raw(path, data)
  return path
end

T["png"]["um PNG de verdade: 1 x 1"] = function()
  local path = put_raw("real.png", vim.base64.decode(fixture.REAL_1X1))
  eq({ png.size(path) }, { 1, 1 })
end

T["png"]["lê largura e altura do IHDR"] = function()
  eq({ png.size(put_png("a.png", 400, 200)) }, { 400, 200 })
  eq({ png.size(put_png("b.png", 3, 65000)) }, { 3, 65000 })
end

T["png"]["o que não é PNG devolve `nil` e o motivo, sem lançar"] = function()
  local cases = {
    ["jpeg.png"] = "\255\216\255\224\0\16JFIF\0\1\1\0\0\1\0\1\0\0",
    ["gif.png"] = "GIF89a\1\0\1\0\128\0\0\0\0\0\255\255\255!\249\4\1\0\0\0\0",
    ["svg.png"] = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>',
    ["text.png"] = "isto não é uma imagem, só um texto com a extensão errada",
    ["short.png"] = "\137PNG\r\n\26\n",
    ["empty.png"] = "",
    ["no_ihdr.png"] = "\137PNG\r\n\26\n" .. string.rep("\0", 16),
    ["zero.png"] = fixture.bytes(0, 10),
    ["huge.png"] = fixture.bytes(70000, 10),
  }
  for name, data in pairs(cases) do
    local width, reason = png.size(put_raw(name, data))
    eq({ name, width }, { name, nil })
    eq({ name, type(reason) }, { name, "string" })
  end
  local width, reason = png.size(ctx.dir .. "/não-existe.png")
  eq(width, nil)
  eq(type(reason), "string")
end

-- ---------------------------------------------------------------------------------------
-- Decisão: há imagem de verdade?
-- ---------------------------------------------------------------------------------------

T["status"] = new_set()

T["status"]["kitty detectado: protocolo kitty e o motivo da detecção"] = function()
  local status = image.status()
  eq(status.protocol, "kitty")
  eq(status.reason:find("kitty", 1, true) ~= nil, true)
  eq(status.caps.graphics, "kitty")
end

T["status"]["sem protocolo gráfico (xterm, burro, tmux mentindo, SSH): nada"] = function()
  for _, env in ipairs({
    { TERM = "xterm-256color" },
    { TERM = "dumb" },
    { TERM = "xterm-kitty", TMUX = "/tmp/tmux-1000/default,1,0" },
    { TERM = "xterm-kitty", SSH_CONNECTION = "10.0.0.2 5000 10.0.0.1 22" },
  }) do
    caps.set_override(env)
    local status = image.status()
    eq({ vim.inspect(env), status.protocol }, { vim.inspect(env), nil })
    eq(type(status.reason), "string")
    eq(image.session(ctx.src), nil)
  end
end

T["status"]["iTerm2, WezTerm e sixel são detectados e não são desenhados: texto alternativo"] = function()
  for _, env in ipairs({
    { TERM = "xterm-256color", TERM_PROGRAM = "iTerm.app" },
    { TERM = "xterm-256color", WEZTERM_PANE = "1" },
    { TERM = "foot" },
  }) do
    caps.set_override(env)
    local status = image.status()
    eq(status.protocol, nil)
    eq(status.caps.layer, 2)
    eq(status.reason:find("not supported yet", 1, true) ~= nil, true)
    eq(image.session(ctx.src), nil)
  end
end

T["status"]["`images.enabled = false` vence um kitty detectado"] = function()
  config().options.images.enabled = false
  local status = image.status()
  eq(status.protocol, nil)
  eq(status.reason:find("images.enabled", 1, true) ~= nil, true)
  eq(image.session(ctx.src), nil)
end

T["status"]["`images.enabled = true` levanta a barra do SSH e do tmux, não a do terminal burro"] = function()
  config().options.images.enabled = true
  caps.set_override({ TERM = "xterm-kitty", SSH_TTY = "/dev/pts/1" })
  eq(image.status().protocol, "kitty")
  caps.set_override({ TERM = "tmux-256color", TMUX = "x", KITTY_WINDOW_ID = "1" })
  eq(image.status().protocol, "kitty")
  caps.set_override({ TERM = "dumb", KITTY_WINDOW_ID = "1" })
  eq(image.status().protocol, nil)
end

T["status"]["`ambiwidth=double` desliga: o placeholder mediria duas células"] = function()
  local saved = vim.o.ambiwidth
  vim.o.ambiwidth = "double"
  local ok, status = pcall(image.status)
  vim.o.ambiwidth = saved
  eq(ok, true)
  eq(status.protocol, nil)
  eq(status.reason:find("ambiwidth", 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------------------
-- O provedor: achar o arquivo e medir
-- ---------------------------------------------------------------------------------------

T["lookup"] = new_set()

T["lookup"]["PNG relativo ao arquivo fonte vira imagem com id, tamanho e grupo de cor"] = function()
  put_png("pic.png", 400, 200)
  local handle = image.session(ctx.src).lookup("pic.png", 60)
  eq(handle.cols, 40)
  eq(handle.rows, 10)
  -- A faixa do deckle: o id é a cor, e o Neovim só escreve `38;5;<id>` de 16 em diante.
  eq(handle.id >= kitty.MIN_ID and handle.id <= kitty.MAX_ID, true)
  eq({ kitty.MIN_ID, kitty.MAX_ID }, { 16, 255 })
  eq(handle.hl, "DeckleImg" .. handle.id)
end

T["lookup"]["o grupo de cor carrega o id: `fg` (cor verdadeira) e `ctermfg` (256 cores)"] = function()
  put_png("pic.png", 100, 100)
  local handle = image.session(ctx.src).lookup("pic.png", 60)
  local hl = vim.api.nvim_get_hl(0, { name = handle.hl })
  eq(hl.fg, handle.id)
  eq(hl.ctermfg, handle.id)
end

T["lookup"]["as formas de escrever o caminho"] = function()
  put_png("img/pic.png", 100, 100)
  put_png("my pic.png", 100, 100)
  put_png("pic.png", 100, 100)
  local session = image.session(ctx.src)
  for _, ref in ipairs({
    "img/pic.png",
    "./img/pic.png",
    "img/../pic.png",
    "my%20pic.png",
    "pic.png?raw=true",
    "pic.png#frag",
    ctx.dir .. "/pic.png",
  }) do
    eq({ ref, session.lookup(ref, 60) ~= nil }, { ref, true })
  end
end

T["lookup"]["o que não é imagem local em PNG vira `nil` (texto alternativo), sem erro"] = function()
  fixture.write_raw(ctx.dir .. "/photo.jpg", "\255\216\255\224\0\16JFIF\0\1\1")
  fixture.write_raw(ctx.dir .. "/fake.png", "texto, não PNG")
  fixture.write_raw(ctx.dir .. "/logo.svg", "<svg></svg>")
  vim.fn.mkdir(ctx.dir .. "/folder.png", "p")
  local session = image.session(ctx.src)
  for _, ref in ipairs({
    "photo.jpg",
    "fake.png",
    "logo.svg",
    "folder.png",
    "nao-existe.png",
    "https://example.com/a.png",
    "http://example.com/a.png",
    "data:image/png;base64,iVBORw0KGgo=",
    "file:///tmp/a.png",
    "//cdn.example.com/a.png",
    "",
  }) do
    eq({ ref, session.lookup(ref, 60) }, { ref, nil })
  end
  eq(ctx.notes, {})
end

T["lookup"]["fonte sem nome: só caminho absoluto resolve"] = function()
  put_png("pic.png", 100, 100)
  local nameless = vim.api.nvim_create_buf(false, true)
  local session = image.session(nameless)
  eq(session.lookup("pic.png", 60), nil)
  eq(session.lookup(ctx.dir .. "/pic.png", 60) ~= nil, true)
  image.clear(nameless)
  vim.api.nvim_buf_delete(nameless, { force = true })
end

T["lookup"]["arquivo maior que o teto vira texto alternativo"] = function()
  put_png("pic.png", 100, 100)
  local saved = image.MAX_FILE_BYTES
  image.MAX_FILE_BYTES = 10
  local handle = image.session(ctx.src).lookup("pic.png", 60)
  image.MAX_FILE_BYTES = saved
  eq(handle, nil)
end

T["lookup"]["tamanho: natural, limitado pela largura e por `max_height`"] = function()
  local cases = {
    -- { largura px, altura px, colunas disponíveis, max_height, colunas, linhas }
    { 400, 200, 60, 20, 40, 10 }, -- tamanho natural
    { 1000, 500, 40, 20, 40, 10 }, -- mais larga que a janela: encolhe para a largura
    { 20, 20, 40, 20, 2, 1 }, -- ícone: não estica até a janela
    { 1000, 500, 40, 5, 20, 5 }, -- teto de altura: encolhe a largura junto, mantém a proporção
    { 100, 2000, 40, 20, 2, 20 }, -- retrato alto
    { 1, 1, 40, 20, 1, 1 }, -- 1 x 1
    { 8000, 8000, 500, 1000, 297, 149 }, -- nunca além da tabela de diacríticos
  }
  for _, case in ipairs(cases) do
    local w, h, avail, max_height, cols, rows = unpack(case)
    config().options.images.max_height = max_height
    put_png("pic.png", w, h)
    local handle = image.session(ctx.src).lookup("pic.png", avail)
    eq({ vim.inspect(case), handle.cols, handle.rows }, { vim.inspect(case), cols, rows })
    image.clear(ctx.src)
  end
end

T["lookup"]["o id é estável entre sessões enquanto o arquivo e o tamanho não mudam"] = function()
  put_png("pic.png", 400, 200)
  local first = image.session(ctx.src).lookup("pic.png", 60)
  local second = image.session(ctx.src).lookup("pic.png", 60)
  eq(second.id, first.id)
  -- Largura diferente é outra imagem para o terminal (outro retângulo).
  local narrow = image.session(ctx.src).lookup("pic.png", 30)
  eq(narrow.id ~= first.id, true)
end

T["lookup"]["acabaram os 240 ids: o resto cai no texto alternativo"] = function()
  put_png("pic.png", 4000, 4000)
  config().options.images.max_height = 1000
  local session = image.session(ctx.src)
  local handles, missing = 0, 0
  -- Cada largura é um retângulo diferente, logo outro id.
  for avail = 10, 265 do
    if session.lookup("pic.png", avail) then
      handles = handles + 1
    else
      missing = missing + 1
    end
  end
  eq({ handles, missing }, { 240, 16 })
end

-- ---------------------------------------------------------------------------------------
-- Escrita: transmitir, posicionar, apagar
-- ---------------------------------------------------------------------------------------

T["commit"] = new_set()

T["commit"]["nada é escrito antes do commit"] = function()
  put_png("pic.png", 400, 200)
  image.session(ctx.src).lookup("pic.png", 60)
  eq(ctx.written, {})
end

T["commit"]["a primeira vez transmite por caminho e posiciona: os bytes do protocolo"] = function()
  local path = put_png("pic.png", 400, 200)
  local session = image.session(ctx.src)
  local handle = session.lookup("pic.png", 60)
  session.commit()

  local id = handle.id
  eq(
    written(),
    ESC
      .. "_Ga=t,f=100,t=f,i="
      .. id
      .. ",q=2;"
      .. b64(vim.fs.normalize(path))
      .. ESC
      .. "\\"
      .. ESC
      .. "_Ga=p,U=1,i="
      .. id
      .. ",c=40,r=10,C=1,q=2"
      .. ESC
      .. "\\"
  )
  eq(#ctx.written, 1) -- uma escrita só
end

T["commit"]["o segundo commit com a mesma imagem não escreve nada"] = function()
  put_png("pic.png", 400, 200)
  local first = image.session(ctx.src)
  first.lookup("pic.png", 60)
  first.commit()
  local count = #ctx.written

  local second = image.session(ctx.src)
  second.lookup("pic.png", 60)
  second.commit()
  eq(#ctx.written, count)
end

T["commit"]["a imagem que sai do documento é apagada, e o id volta"] = function()
  put_png("pic.png", 400, 200)
  local first = image.session(ctx.src)
  local handle = first.lookup("pic.png", 60)
  first.commit()
  eq(#image.placements(ctx.src), 1)

  ctx.written = {}
  local second = image.session(ctx.src)
  second.commit() -- este render não pediu imagem nenhuma
  eq(written(), ESC .. "_Ga=d,d=I,i=" .. handle.id .. ",q=2" .. ESC .. "\\")
  eq(image.placements(ctx.src), {})
end

T["commit"]["o arquivo que muda (tamanho ou data) é transmitido de novo, com outro id"] = function()
  local path = put_png("pic.png", 400, 200)
  local first = image.session(ctx.src)
  local old = first.lookup("pic.png", 60)
  first.commit()

  ctx.written = {}
  put_png("pic.png", 400, 400) -- mesmo caminho, outra imagem
  vim.uv.fs_utime(path, 1, 1)
  local second = image.session(ctx.src)
  local new = second.lookup("pic.png", 60)
  second.commit()
  eq(new.id ~= old.id, true)
  eq(new.rows, 20)
  eq(written():find("a=d,d=I,i=" .. old.id .. ",", 1, true) ~= nil, true)
  eq(written():find("a=t,f=100,t=f,i=" .. new.id .. ",", 1, true) ~= nil, true)
end

T["commit"]["as imagens saem em ordem de id: a saída é determinística"] = function()
  put_png("a.png", 100, 100)
  put_png("b.png", 200, 100)
  put_png("c.png", 300, 100)
  local session = image.session(ctx.src)
  local handles = {
    session.lookup("c.png", 60),
    session.lookup("a.png", 60),
    session.lookup("b.png", 60),
  }
  session.commit()
  local order = {}
  for id in written():gmatch("a=t,f=100,t=f,i=(%d+),") do
    order[#order + 1] = tonumber(id)
  end
  local ids = vim.tbl_map(function(h)
    return h.id
  end, handles)
  table.sort(ids)
  eq(order, ids)
end

T["commit"]["`reset` faz o próximo commit retransmitir, com os mesmos ids"] = function()
  put_png("pic.png", 400, 200)
  local first = image.session(ctx.src)
  local handle = first.lookup("pic.png", 60)
  first.commit()
  local sent = written()
  ctx.written = {}

  image.reset(ctx.src)
  local second = image.session(ctx.src)
  eq(second.lookup("pic.png", 60).id, handle.id)
  second.commit()
  eq(written(), sent)
end

T["commit"]["`clear` apaga cada imagem enviada e esquece tudo; chamar de novo não escreve"] = function()
  put_png("a.png", 100, 100)
  put_png("b.png", 200, 100)
  local session = image.session(ctx.src)
  local a = session.lookup("a.png", 60)
  local b = session.lookup("b.png", 60)
  session.commit()
  ctx.written = {}

  image.clear(ctx.src)
  local text = written()
  eq(text:find("a=d,d=I,i=" .. a.id .. ",q=2", 1, true) ~= nil, true)
  eq(text:find("a=d,d=I,i=" .. b.id .. ",q=2", 1, true) ~= nil, true)
  eq(image.placements(ctx.src), {})

  ctx.written = {}
  image.clear(ctx.src)
  eq(ctx.written, {})
end

T["commit"]["`clear` não apaga o que nunca foi enviado"] = function()
  put_png("pic.png", 400, 200)
  image.session(ctx.src).lookup("pic.png", 60) -- sem commit
  image.clear(ctx.src)
  eq(ctx.written, {})
end

T["commit"]["`clear_all` apaga as imagens de todos os previews (a rede de segurança do `VimLeavePre`)"] = function()
  put_png("pic.png", 400, 200)
  local other = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(other, ctx.dir .. "/other.md")
  for _, buf in ipairs({ ctx.src, other }) do
    local session = image.session(buf)
    session.lookup("pic.png", 60)
    session.commit()
  end
  ctx.written = {}

  local group = vim.api.nvim_get_autocmds({ group = "deckle_image", event = "VimLeavePre" })
  eq(#group, 1)
  vim.api.nvim_exec_autocmds("VimLeavePre", { group = "deckle_image", modeline = false })
  local _, count = written():gsub("a=d,d=I", "")
  eq(count, 2)
  eq(image.placements(ctx.src), {})
  eq(image.placements(other), {})
  vim.api.nvim_buf_delete(other, { force = true })
end

T["commit"]["dentro do tmux cada escape sai embrulhado para o repasse"] = function()
  caps.set_override(
    { TERM = "tmux-256color", TMUX = "/tmp/tmux-1000/default,1,0", KITTY_WINDOW_ID = "1" },
    true
  )
  put_png("pic.png", 400, 200)
  local session = image.session(ctx.src)
  session.lookup("pic.png", 60)
  session.commit()

  local text = written()
  eq(vim.startswith(text, ESC .. "Ptmux;" .. ESC .. ESC .. "_Ga=t,"), true)
  -- Dois escapes (transmitir e posicionar), cada um no seu `DCS tmux`.
  local _, wrapped = text:gsub(ESC .. "Ptmux;", "")
  eq(wrapped, 2)
  -- Nenhum ESC solto dentro do repasse: todos dobrados.
  eq(
    text:gsub(ESC .. "Ptmux;", ""):gsub(ESC .. ESC, ""):gsub(ESC .. "\\", ""):find(ESC, 1, true),
    nil
  )
end

T["commit"]["sessão remota (SSH com opt-in): os bytes vão pelo tty, em pedaços, não o caminho"] = function()
  config().options.images.enabled = true
  caps.set_override({ TERM = "xterm-kitty", SSH_CONNECTION = "10.0.0.2 5000 10.0.0.1 22" })
  local path = ctx.dir .. "/big.png"
  fixture.write_raw(path, fixture.bytes(400, 200) .. string.rep("\1", 7000))
  local session = image.session(ctx.src)
  local handle = session.lookup("big.png", 60)
  session.commit()

  local text = written()
  eq(text:find("t=f", 1, true), nil)
  eq(text:find("a=t,f=100,t=d,i=" .. handle.id .. ",q=2,m=1;", 1, true) ~= nil, true)
  eq(text:find(ESC .. "_Gm=0,q=2;", 1, true) ~= nil, true)
  eq(text:find("a=p,U=1,i=" .. handle.id .. ",c=40,r=10", 1, true) ~= nil, true)

  local payload = {}
  for chunk in text:gmatch(";([%w+/=]+)" .. ESC .. "\\") do
    payload[#payload + 1] = chunk
  end
  eq(vim.base64.decode(table.concat(payload)), fixture.bytes(400, 200) .. string.rep("\1", 7000))
end

T["commit"]["sessão remota: arquivo grande demais para ir pelo tty vira texto alternativo"] = function()
  config().options.images.enabled = true
  caps.set_override({ TERM = "xterm-kitty", SSH_CONNECTION = "10.0.0.2 5000 10.0.0.1 22" })
  fixture.write_raw(ctx.dir .. "/big.png", fixture.bytes(400, 200) .. string.rep("\1", 50))
  local saved = image.MAX_DIRECT_BYTES
  image.MAX_DIRECT_BYTES = 40
  local handle = image.session(ctx.src).lookup("big.png", 60)
  image.MAX_DIRECT_BYTES = saved
  eq(handle, nil)
end

T["commit"]["writer que lança vira aviso uma vez, e o commit não propaga o erro"] = function()
  image.set_writer(function()
    error("tty closed")
  end)
  put_png("pic.png", 400, 200)
  local session = image.session(ctx.src)
  session.lookup("pic.png", 60)
  eq(pcall(session.commit), true)
  eq(#ctx.notes, 1)
  eq(ctx.notes[1].msg:find("tty closed", 1, true) ~= nil, true)
  eq(ctx.notes[1].level, vim.log.levels.WARN)

  -- O mesmo erro de novo (agora ao apagar) não vira um segundo aviso.
  eq(pcall(image.clear, ctx.src), true)
  eq(#ctx.notes, 1)
end

T["commit"]["preview fechado no meio do render: o commit atrasado não escreve"] = function()
  put_png("pic.png", 400, 200)
  local session = image.session(ctx.src)
  session.lookup("pic.png", 60)
  image.clear(ctx.src)
  session.commit()
  eq(ctx.written, {})
end

-- ---------------------------------------------------------------------------------------
-- O writer padrão nunca escreve no terminal real durante os testes
-- ---------------------------------------------------------------------------------------

T["writer padrão"] = new_set()

T["writer padrão"]["sem interface de terminal (headless) não escreve em canal nenhum"] = function()
  image.set_writer(nil)
  local sends = {}
  local real = vim.api.nvim_chan_send
  vim.api.nvim_chan_send = function(chan, data)
    sends[#sends + 1] = { chan, data }
  end
  local uis = vim.api.nvim_list_uis
  vim.api.nvim_list_uis = function()
    return {}
  end

  put_png("pic.png", 400, 200)
  local session = image.session(ctx.src)
  session.lookup("pic.png", 60)
  local ok = pcall(session.commit)

  vim.api.nvim_chan_send = real
  vim.api.nvim_list_uis = uis
  eq(ok, true)
  eq(sends, {})
end

T["writer padrão"]["com TUI escreve em `vim.v.stderr`, que é o tty (o stdout é o RPC)"] = function()
  image.set_writer(nil)
  local sends = {}
  local real = vim.api.nvim_chan_send
  vim.api.nvim_chan_send = function(chan, data)
    sends[#sends + 1] = { chan = chan, data = data }
  end
  local uis = vim.api.nvim_list_uis
  vim.api.nvim_list_uis = function()
    return { { chan = 1, stdout_tty = true } }
  end

  put_png("pic.png", 400, 200)
  local session = image.session(ctx.src)
  local handle = session.lookup("pic.png", 60)
  session.commit()

  vim.api.nvim_chan_send = real
  vim.api.nvim_list_uis = uis
  eq(#sends, 1)
  eq(sends[1].chan, vim.v.stderr)
  eq(sends[1].data:find("a=t,f=100,t=f,i=" .. handle.id .. ",", 1, true) ~= nil, true)
end

T["writer padrão"]["UI que não é um terminal (GUI) também não recebe os escapes"] = function()
  image.set_writer(nil)
  local sends = 0
  local real = vim.api.nvim_chan_send
  vim.api.nvim_chan_send = function()
    sends = sends + 1
  end
  local uis = vim.api.nvim_list_uis
  vim.api.nvim_list_uis = function()
    return { { chan = 3, stdout_tty = false } }
  end

  put_png("pic.png", 400, 200)
  local session = image.session(ctx.src)
  session.lookup("pic.png", 60)
  session.commit()

  vim.api.nvim_chan_send = real
  vim.api.nvim_list_uis = uis
  eq(sends, 0)
end

-- ---------------------------------------------------------------------------------------
-- O gancho do render
-- ---------------------------------------------------------------------------------------

T["render"] = new_set()

---@param handle deckle.ImageHandle|nil
---@return table provider, table[] calls
local function fake_provider(handle)
  local calls = {}
  return {
    lookup = function(src, width)
      calls[#calls + 1] = { src = src, width = width }
      return handle
    end,
  },
    calls
end

local HANDLE = { id = 5, cols = 4, rows = 3, hl = "DeckleImg5" }

---@param text string
---@param opts table|nil
---@return deckle.RenderResult
local function r(text, opts)
  return render.render(
    parse.parse_lines(text),
    vim.tbl_extend("force", { width = 40, charset = "unicode" }, opts or {})
  )
end

T["render"]["parágrafo que é só uma imagem vira N linhas de placeholder, com marca e mapa"] = function()
  local provider, calls = fake_provider(HANDLE)
  local result = r("![foto](pic.png)", { images = provider })

  eq(calls, { { src = "pic.png", width = 40 } })
  eq(#result.lines, 3)
  for row, line in ipairs(result.lines) do
    eq(line, kitty.placeholder_row(row - 1, 4))
    eq(vim.fn.strdisplaywidth(line), 4)
    eq(result.marks[row], { row = row - 1, col = 0, end_col = #line, hl = "DeckleImg5" })
  end
  eq(result.map, { { preview_start = 0, preview_end = 3, src_start = 0, src_end = 1 } })
end

T["render"]["o bloco de imagem entra no mapa como qualquer outro, entre dois blocos de texto"] = function()
  local provider = fake_provider(HANDLE)
  local result = r("antes\n\n![foto](pic.png)\n\ndepois", { images = provider })
  eq(#result.lines, 1 + 1 + 3 + 1 + 1)
  eq(result.map, {
    { preview_start = 0, preview_end = 1, src_start = 0, src_end = 1 },
    { preview_start = 2, preview_end = 5, src_start = 2, src_end = 3 },
    { preview_start = 6, preview_end = 7, src_start = 4, src_end = 5 },
  })
  -- A sincronia da fase 3 resolve sobre ele sem saber que ali tem uma imagem.
  local sync = require("deckle.sync")
  eq(sync.src_to_preview(result.map, 2), 2)
  eq(sync.src_to_preview(result.map, 4), 6)
  eq(sync.preview_to_src(result.map, 4), 2)
  eq(sync.preview_to_src(result.map, 6), 4)
end

T["render"]["espaço em volta da imagem é ignorado"] = function()
  local provider = fake_provider(HANDLE)
  eq(#r("   ![foto](pic.png)   ", { images = provider }).lines, 3)
end

T["render"]["dentro de uma citação o bloco leva o prefixo e a marca anda junto"] = function()
  local provider, calls = fake_provider(HANDLE)
  local result = r("> ![foto](pic.png)", { images = provider })
  -- A largura que o provedor recebe já desconta o prefixo `│ `.
  eq(calls[1].width, 38)
  eq(#result.lines, 3)
  for row, line in ipairs(result.lines) do
    eq(vim.startswith(line, "│ "), true)
    eq(line:sub(#"│ " + 1), kitty.placeholder_row(row - 1, 4))
    eq(result.marks[row].hl, "DeckleImg5")
  end
end

T["render"]["o que não é uma imagem sozinha segue como texto alternativo, sem consultar o provedor"] = function()
  local cases = {
    "antes ![logo](a.png) depois",
    "![a](a.png) depois",
    "[![build](a.png)](http://ci)",
    "![a](a.png)\n![b](b.png)",
    "![a](a.png) ![b](b.png)",
    "![a](a.png)  \nfim",
    "![](a.png)x",
    "- ![a](a.png)",
  }
  for _, text in ipairs(cases) do
    local provider, calls = fake_provider(HANDLE)
    local with = r(text, { images = provider })
    local without = r(text)
    eq({ text, with.lines }, { text, without.lines })
    eq({ text, with.marks }, { text, without.marks })
    eq({ text, calls }, { text, {} })
  end
end

T["render"]["imagem sem destino não consulta o provedor"] = function()
  local provider, calls = fake_provider(HANDLE)
  eq(r("![vazia]()", { images = provider }).lines, { "[image: vazia]" })
  eq(calls, {})
end

T["render"]["provedor que recusa (`nil`): o texto alternativo de sempre"] = function()
  local provider, calls = fake_provider(nil)
  local result = r("![logo](x.png)", { images = provider })
  eq(calls, { { src = "x.png", width = 40 } })
  eq(result.lines, { "[image: logo]" })
  eq(result.marks, { { row = 0, col = 0, end_col = 13, hl = "DeckleImage" } })
end

T["render"]["gate 2: sem protocolo o render é idêntico ao da camada 0, em todos os fixtures"] = function()
  local files = vim.fn.glob(tests_dir .. "/fixtures/*.md", false, true)
  files[#files + 1] = vim.fn.fnamemodify(tests_dir, ":h") .. "/README.md"
  eq(#files > 8, true)

  local never = {
    lookup = function()
      return nil
    end,
  }
  for _, path in ipairs(files) do
    local ir = parse.parse_lines(table.concat(vim.fn.readfile(path), "\n"))
    for _, width in ipairs({ 20, 60, 100 }) do
      local base = render.render(ir, { width = width, charset = "unicode" })
      local no_provider = render.render(ir, { width = width, charset = "unicode", images = nil })
      local refusing = render.render(ir, { width = width, charset = "unicode", images = never })
      eq({ path, width, no_provider }, { path, width, base })
      eq({ path, width, refusing }, { path, width, base })
    end
  end
end

return T
