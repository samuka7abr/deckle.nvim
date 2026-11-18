-- Testes de `deckle.sync` (fase 3): a busca binária sobre o mapa e a sincronia de cursor entre
-- o fonte e o preview.
--
-- A busca (`locate`, `src_to_preview`, `preview_to_src`) é função pura do mapa. Os casos dela
-- rodam sem Neovim filho, e o módulo é carregado com `vim` barrado no ambiente: se uma dessas
-- funções encostar na API do editor, o caso falha com mensagem.
--
-- A integração roda num Neovim filho, com teclas reais (`child.type_keys`). `CursorMoved` só
-- dispara quando o laço principal anda, e o que o faz andar é uma tecla; `nvim_win_set_cursor`
-- sozinho não dispara nada. As trocas de janela também são feitas por tecla (`<C-w>l`): é o
-- que faz o Neovim entregar `CursorMoved` na janela em que se entra, e esse é o evento que o
-- `expect` do módulo existe para reconhecer.
--
-- Os documentos usam só título, parágrafo, lista e citação, que não mudam com as fases de
-- tabela e de código.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h")

local child = MiniTest.new_child_neovim()

local T = new_set()

-- ---------------------------------------------------------------------------------------
-- Apoio: busca pura
-- ---------------------------------------------------------------------------------------

--- `deckle.sync` carregado num ambiente que só tem `math`: o que a busca faz tem que sair só de
--- Lua. `vim`, e qualquer outro global, lança erro se uma função pura chegar a tocá-lo.
---@return table
local function load_pure()
  local chunk = assert(loadfile(vim.fn.fnamemodify(tests_dir, ":h") .. "/lua/deckle/sync.lua"))
  setfenv(
    chunk,
    setmetatable({ math = math }, {
      __index = function(_, key)
        error("a busca não pode usar o global `" .. tostring(key) .. "`", 2)
      end,
    })
  )
  return chunk()
end

local pure = load_pure()

---@param ps integer
---@param pe integer
---@param ss integer
---@param se integer
---@return deckle.MapEntry
local function entry(ps, pe, ss, se)
  return { preview_start = ps, preview_end = pe, src_start = ss, src_end = se }
end

--- Gerador congruencial: independe do estado global de `math.random`.
---@param seed integer
---@return fun(n: integer): integer  sorteia de 1 a n
local function rng(seed)
  local state = seed
  return function(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return (math.floor(state / 65536) % n) + 1
  end
end

--- Mapa aleatório, mas com a forma que o render produz: em ordem nos dois lados, sem
--- sobreposição, com folga (possivelmente nenhuma) entre os blocos do fonte e uma linha em
--- branco entre os do preview.
---@param count integer
---@param seed integer
---@return deckle.MapEntry[]
local function random_map(count, seed)
  local next_int = rng(seed)
  local map = {}
  local p, s = next_int(3) - 1, next_int(4) - 1
  for i = 1, count do
    local plen, slen = next_int(8), next_int(6)
    map[i] = entry(p, p + plen, s, s + slen)
    p = p + plen + 1
    s = s + slen + next_int(4) - 1
  end
  return map
end

--- Resposta de `locate` por varredura linear, a referência da busca binária.
---@param map deckle.MapEntry[]
---@param side "src"|"preview"
---@param line integer
---@return integer index, boolean inside
local function oracle(map, side, line)
  local first, last = side .. "_start", side .. "_end"
  for i, e in ipairs(map) do
    if e[first] <= line and line < e[last] then
      return i, true
    end
  end
  if line < map[1][first] then
    return 1, false
  end
  if line >= map[#map][last] then
    return #map, false
  end
  for i = 1, #map - 1 do
    if map[i][last] <= line and line < map[i + 1][first] then
      local above = line - (map[i][last] - 1)
      local below = map[i + 1][first] - line
      return (below < above) and (i + 1) or i, false
    end
  end
  error("linha fora de qualquer faixa")
end

-- ---------------------------------------------------------------------------------------
-- Gate 1: a busca binária, isolada
-- ---------------------------------------------------------------------------------------

T["busca"] = new_set()

T["busca"]["mapa vazio: nada resolve"] = function()
  eq({ pure.locate({}, "src", 5) }, { nil, false })
  eq({ pure.locate({}, "preview", 0) }, { nil, false })
  eq(pure.src_to_preview({}, 0), nil)
  eq(pure.preview_to_src({}, 0), nil)
end

T["busca"]["uma entrada: dentro, antes e depois"] = function()
  local map = { entry(2, 5, 10, 13) } -- 3 linhas no fonte, 3 no preview

  -- Dentro: tamanhos iguais, a conta é a identidade deslocada.
  eq(pure.src_to_preview(map, 10), 2)
  eq(pure.src_to_preview(map, 11), 3)
  eq(pure.src_to_preview(map, 12), 4)
  eq(pure.preview_to_src(map, 2), 10)
  eq(pure.preview_to_src(map, 4), 12)
  eq({ pure.locate(map, "src", 11) }, { 1, true })

  -- Antes: a primeira linha do bloco. Depois: a última.
  eq(pure.src_to_preview(map, 0), 2)
  eq(pure.src_to_preview(map, 9), 2)
  eq(pure.src_to_preview(map, 13), 4)
  eq(pure.src_to_preview(map, 999), 4)
  eq(pure.preview_to_src(map, 0), 10)
  eq(pure.preview_to_src(map, 5), 12)
  eq({ pure.locate(map, "src", 9) }, { 1, false })
  eq({ pure.locate(map, "src", 13) }, { 1, false })
end

T["busca"]["linha antes da primeira entrada resolve para a primeira"] = function()
  local map = { entry(0, 2, 5, 7), entry(3, 4, 9, 10), entry(5, 8, 12, 14) }
  eq({ pure.locate(map, "src", 0) }, { 1, false })
  eq({ pure.locate(map, "src", 4) }, { 1, false })
  eq(pure.src_to_preview(map, 0), 0)
  eq(pure.src_to_preview(map, 4), 0)

  -- No lado do preview o primeiro bloco começa na linha 0, então "antes" precisa de outro mapa.
  local shifted = { entry(4, 6, 0, 2), entry(7, 8, 3, 4) }
  eq({ pure.locate(shifted, "preview", 0) }, { 1, false })
  eq(pure.preview_to_src(shifted, 0), 0)
  eq(pure.preview_to_src(shifted, 3), 0)
end

T["busca"]["linha depois da última entrada resolve para a última"] = function()
  local map = { entry(0, 2, 5, 7), entry(3, 4, 9, 10), entry(5, 8, 12, 14) }
  eq({ pure.locate(map, "src", 14) }, { 3, false })
  eq({ pure.locate(map, "src", 500) }, { 3, false })
  eq(pure.src_to_preview(map, 14), 7) -- última linha do último bloco do preview
  eq(pure.src_to_preview(map, 500), 7)
  eq(pure.preview_to_src(map, 8), 13)
  eq(pure.preview_to_src(map, 500), 13)
end

T["busca"]["bloco de N linhas do fonte para 1 do preview: toda linha cai nessa uma"] = function()
  local map = { entry(0, 1, 0, 1), entry(2, 3, 2, 12), entry(4, 5, 13, 14) }
  for line = 2, 11 do
    eq(pure.src_to_preview(map, line), 2)
    eq({ pure.locate(map, "src", line) }, { 2, true })
  end
  -- E a volta cai no começo do bloco.
  eq(pure.preview_to_src(map, 2), 2)
end

T["busca"]["bloco de 1 linha do fonte para N do preview: a linha cai na primeira, e a volta cobre o bloco"] = function()
  local map = { entry(0, 6, 4, 5) }
  eq(pure.src_to_preview(map, 4), 0)
  for line = 0, 5 do
    eq(pure.preview_to_src(map, line), 4)
  end
end

T["busca"]["bloco de N para M interpola, dentro do bloco e em ordem"] = function()
  local map = { entry(10, 14, 0, 8) } -- 8 linhas do fonte para 4 do preview
  local previous = -1
  for line = 0, 7 do
    local p = pure.src_to_preview(map, line)
    eq(p >= 10 and p < 14, true)
    eq(p >= previous, true)
    previous = p
  end
  eq(pure.src_to_preview(map, 0), 10)
  eq(pure.src_to_preview(map, 7), 13)
  eq(pure.src_to_preview(map, 4), 12)
end

T["busca"]["as bordas de um bloco: a primeira linha e a última estão dentro, a seguinte não"] = function()
  local map = { entry(0, 2, 3, 6), entry(3, 5, 8, 9) }
  eq({ pure.locate(map, "src", 3) }, { 1, true })
  eq({ pure.locate(map, "src", 5) }, { 1, true })
  eq({ pure.locate(map, "src", 6) }, { 1, false })
  eq({ pure.locate(map, "src", 8) }, { 2, true })
  eq({ pure.locate(map, "src", 9) }, { 2, false })
end

T["busca"]["entre dois blocos: o mais próximo pela borda, e empate fica com o de cima"] = function()
  -- Fonte: bloco A nas linhas 0..4, três linhas em branco (5, 6 e 7), bloco B nas 8..10.
  local map = { entry(0, 3, 0, 5), entry(4, 6, 8, 11) }
  -- A linha 5 está a 1 da última do A e a 3 da primeira do B.
  eq({ pure.locate(map, "src", 5) }, { 1, false })
  -- A linha 6: a 2 de cada. Empate, vale o bloco de cima.
  eq({ pure.locate(map, "src", 6) }, { 1, false })
  -- A linha 7: a 3 do A e a 1 do B.
  eq({ pure.locate(map, "src", 7) }, { 2, false })

  -- O destino é a borda do bloco escolhido, sem interpolar.
  eq(pure.src_to_preview(map, 5), 2) -- última linha do A no preview
  eq(pure.src_to_preview(map, 6), 2)
  eq(pure.src_to_preview(map, 7), 4) -- primeira linha do B no preview
end

T["busca"]["uma linha em branco entre blocos é empate e vale o bloco de cima, nos dois lados"] = function()
  local map = { entry(0, 2, 0, 1), entry(3, 4, 2, 3) }
  eq({ pure.locate(map, "src", 1) }, { 1, false })
  eq(pure.src_to_preview(map, 1), 1)
  eq({ pure.locate(map, "preview", 2) }, { 1, false })
  eq(pure.preview_to_src(map, 2), 0)
end

T["busca"]["blocos colados no fonte (sem linha em branco) não deixam fresta"] = function()
  local map = { entry(0, 1, 0, 2), entry(2, 3, 2, 3) } -- src_end == src_start do seguinte
  eq({ pure.locate(map, "src", 1) }, { 1, true })
  eq({ pure.locate(map, "src", 2) }, { 2, true })
end

T["busca"]["busca binária confere com a varredura linear, em mapas aleatórios"] = function()
  for seed = 1, 60 do
    local map = random_map(1 + (seed % 17), seed)
    for _, side in ipairs({ "src", "preview" }) do
      local last = map[#map][side .. "_end"]
      for line = -2, last + 2 do
        local want_i, want_inside = oracle(map, side, line)
        local i, inside = pure.locate(map, side, line)
        if i ~= want_i or inside ~= want_inside then
          error(
            string.format(
              "seed %d, lado %s, linha %d: obtido (%s, %s), esperado (%d, %s)",
              seed,
              side,
              line,
              tostring(i),
              tostring(inside),
              want_i,
              tostring(want_inside)
            )
          )
        end
      end
    end
  end
end

T["busca"]["o resultado é monótono, fica no mapa e, dentro de um bloco, fica no bloco"] = function()
  local function check(map, fn, side, other)
    local low = map[1][other .. "_start"]
    local high = map[#map][other .. "_end"] - 1
    local previous = -math.huge
    for line = -3, map[#map][side .. "_end"] + 3 do
      local result = fn(map, line)
      assert(result >= low and result <= high, "resultado fora do mapa")
      assert(result >= previous, "resultado não monótono na linha " .. line)
      previous = result
      local index, inside = pure.locate(map, side, line)
      if inside then
        local e = map[index]
        assert(result >= e[other .. "_start"] and result < e[other .. "_end"], "fora do bloco")
      end
    end
  end

  for seed = 100, 160 do
    local map = random_map(1 + (seed % 23), seed)
    check(map, pure.src_to_preview, "src", "preview")
    check(map, pure.preview_to_src, "preview", "src")
  end
end

T["busca"]["mapa de 100 mil blocos: 20 mil buscas cabem num orçamento folgado"] = function()
  local map = {}
  for i = 1, 100000 do
    map[i] = entry(i * 5, i * 5 + 4, i * 3, i * 3 + 2)
  end
  local last = map[#map].src_end
  local started = vim.uv.hrtime()
  local sum = 0
  for i = 1, 20000 do
    sum = sum + pure.src_to_preview(map, (i * 7919) % last)
  end
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  eq(sum > 0, true)
  -- Por volta de um milissegundo numa máquina comum: um segundo é folga para a CI mais lenta.
  eq(elapsed_ms < 1000, true)
end

T["busca"]["o módulo real e o carregado sem `vim` dão as mesmas respostas"] = function()
  local real = require("deckle.sync")
  local map = random_map(12, 7)
  for line = -2, map[#map].src_end + 2 do
    eq(real.src_to_preview(map, line), pure.src_to_preview(map, line))
  end
end

-- ---------------------------------------------------------------------------------------
-- Apoio: Neovim filho
-- ---------------------------------------------------------------------------------------

local function restart_child()
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.o.columns = 120
  child.o.lines = 40
  child.lua([==[
    -- `vim.notify` coletado: o módulo avisa por notify em vez de lançar.
    _G.notes = {}
    vim.notify = function(msg, level)
      table.insert(_G.notes, { msg = msg, level = level })
    end

    _G.state = function()
      return require("deckle.preview").state(_G.src)
    end

    -- Autocmds de sync que existem agora, e os que o deckle tem de qualquer tipo.
    _G.census = function()
      local out = { autocmds = 0, deckle_autocmds = 0, sync_autocmds = 0, sync_groups = 0 }
      local seen = {}
      for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
        out.autocmds = out.autocmds + 1
        local group = au.group_name or ""
        if group:find("^deckle_") then
          out.deckle_autocmds = out.deckle_autocmds + 1
        end
        if group:find("^deckle_sync_") then
          out.sync_autocmds = out.sync_autocmds + 1
          if not seen[group] then
            seen[group] = true
            out.sync_groups = out.sync_groups + 1
          end
        end
      end
      return out
    end

    _G.wait_for = function(cond)
      return vim.wait(2000, cond, 10)
    end
  ]==])
end

local hooks = { pre_case = restart_child, post_once = child.stop }

--- Cria um buffer fonte com `lines` na janela atual e o guarda em `_G.src`.
---@param lines string[]
local function use_source(lines)
  child.lua(
    [[
      vim.cmd("enew")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, (...))
      vim.bo.filetype = "markdown"
      vim.o.scrolloff = 0
      _G.src = vim.api.nvim_get_current_buf()
      _G.src_win = vim.api.nvim_get_current_win()
    ]],
    { lines }
  )
end

---@return table
local function state()
  return child.lua_get("_G.state()")
end

---@return integer
local function src_win()
  return child.lua_get("_G.src_win")
end

---@return integer
local function src_buf()
  return child.lua_get("_G.src")
end

---@return table
local function census()
  return child.lua_get("_G.census()")
end

--- Linha do cursor de `win`, 0-indexada.
---@param win integer
---@return integer
local function cursor(win)
  return child.api.nvim_win_get_cursor(win)[1] - 1
end

--- Texto da linha `line` (0-indexada) de `buf`.
---@param buf integer
---@param line integer
---@return string
local function text_at(buf, line)
  return child.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
end

---@param win integer
---@return table
local function view(win)
  return child.lua_get(("vim.api.nvim_win_call(%d, vim.fn.winsaveview)"):format(win))
end

---@param n integer
local function wait_renders(n)
  eq(child.lua_get(("_G.wait_for(function() return _G.state().renders >= %d end)"):format(n)), true)
end

--- Documento com blocos de alturas diferentes. Linhas do fonte (0-indexadas):
---   0 título, 1 em branco, 2 parágrafo, 3 em branco, 4-5 lista, 6 em branco, 7 citação,
---   8 em branco, 9 parágrafo.
--- No preview: título e sublinhado (0-1), branco, parágrafo (3), branco, lista (5-6), branco,
--- citação (8), branco, parágrafo (10).
local DOC = {
  "# Titulo",
  "",
  "primeiro paragrafo",
  "",
  "- item a",
  "- item b",
  "",
  "> citacao",
  "",
  "ultimo paragrafo",
}

--- `count` parágrafos de uma linha, separados por linha em branco: o parágrafo `i` (1-indexado)
--- está na linha `2 * (i - 1)` do fonte e na mesma linha do preview. Mapa identidade, para
--- conferir alinhamento de janela sem a aproximação do wrap.
---@param count integer
---@return string[]
local function identity_doc(count)
  local lines = {}
  for i = 1, count do
    lines[#lines + 1] = "par " .. i
    lines[#lines + 1] = ""
  end
  return lines
end

--- Parágrafo de 6 linhas curtas no fonte que o preview junta numa linha só (N para 1).
local NARROW = {
  "# Titulo",
  "",
  "um",
  "dois",
  "tres",
  "quatro",
  "cinco",
  "seis",
  "",
  "fim",
}

-- ---------------------------------------------------------------------------------------
-- Cursor do fonte -> preview, e o inverso
-- ---------------------------------------------------------------------------------------

T["sincronia"] = new_set({ hooks = hooks })

T["sincronia"]["o cursor do fonte leva o preview ao bloco dele"] = function()
  use_source(DOC)
  child.cmd("Deckle open")
  local s = state()
  local win = src_win()

  -- Linha do fonte (1-indexada) -> texto esperado na linha do cursor do preview.
  local cases = {
    { 3, "primeiro paragrafo" },
    { 5, "item a" },
    { 6, "item b" },
    { 8, "citacao" },
    { 10, "ultimo paragrafo" },
    { 1, "Titulo" },
  }
  for _, case in ipairs(cases) do
    child.type_keys(("%dG"):format(case[1]))
    local at = text_at(s.buf, cursor(s.win))
    eq(at:find(case[2], 1, true) ~= nil, true)
    eq(child.api.nvim_get_current_win(), win) -- o foco não saiu do fonte
  end
end

T["sincronia"]["o cursor do preview leva o fonte ao bloco dele"] = function()
  use_source(DOC)
  child.cmd("Deckle open")
  local s = state()

  child.type_keys("<C-w>l")
  eq(child.api.nvim_get_current_win(), s.win)

  -- Linha do preview (1-indexada) -> texto esperado na linha do cursor do fonte.
  local cases = {
    { 4, "primeiro paragrafo" },
    { 6, "- item a" },
    { 7, "- item b" },
    { 9, "> citacao" },
    { 11, "ultimo paragrafo" },
    { 1, "# Titulo" },
  }
  for _, case in ipairs(cases) do
    child.type_keys(("%dG"):format(case[1]))
    eq(text_at(s.src_buf, cursor(src_win())), case[2])
  end
end

T["sincronia"]["linha em branco entre blocos resolve para o bloco de cima (empate)"] = function()
  use_source(DOC)
  child.cmd("Deckle open")
  local s = state()

  -- Fonte 2 (1-indexada), a linha em branco depois do título: vai para a última linha do
  -- bloco de cima no preview, o sublinhado do H1.
  child.type_keys("2G")
  eq(cursor(s.win), s.map[1].preview_end - 1)
  eq(text_at(s.buf, cursor(s.win)):find("═", 1, true) ~= nil, true)

  -- Preview, a linha em branco depois do título: a última linha do bloco de cima no fonte.
  child.type_keys("<C-w>l")
  child.type_keys("3G")
  eq(cursor(src_win()), s.map[1].src_end - 1)
end

T["sincronia"]["linha dentro de um bloco de N linhas do fonte para 1 do preview"] = function()
  use_source(NARROW)
  child.cmd("Deckle open")
  local s = state()
  -- As 6 linhas do parágrafo viram uma só no preview.
  eq(text_at(s.buf, s.map[2].preview_start), "um dois tres quatro cinco seis")
  eq(s.map[2].preview_end - s.map[2].preview_start, 1)

  for line = 3, 8 do
    child.type_keys(("%dG"):format(line))
    eq(cursor(s.win), s.map[2].preview_start)
  end
end

T["sincronia"]["abrir o preview já o alinha ao cursor do fonte"] = function()
  use_source(identity_doc(200))
  child.api.nvim_win_set_cursor(src_win(), { 101, 0 })
  child.cmd("Deckle open")
  local s = state()
  eq(cursor(s.win), 100)
  eq(text_at(s.buf, cursor(s.win)), "par 51")
end

T["sincronia"]["trocar de janela não move o cursor do outro lado (parágrafo de 6 linhas para 1)"] = function()
  use_source(NARROW)
  child.cmd("Deckle open")
  local s = state()

  child.type_keys("6G") -- "quatro", o meio do parágrafo
  eq(cursor(src_win()), 5)

  child.type_keys("<C-w>l")
  eq(cursor(src_win()), 5) -- entrar no preview não empurra o fonte para o começo do bloco
  child.type_keys("<C-w>h")
  eq(cursor(src_win()), 5)
  eq(cursor(s.win), s.map[2].preview_start)

  -- E ir e voltar várias vezes não faz o cursor andar.
  for _ = 1, 4 do
    child.type_keys("<C-w>l", "<C-w>h")
  end
  eq(cursor(src_win()), 5)
end

-- ---------------------------------------------------------------------------------------
-- Gate 2: sem loop, contando os disparos
-- ---------------------------------------------------------------------------------------

T["sincronia"]["mover o cursor dos dois lados não faz loop: cada movimento é um evento na origem"] = function()
  use_source(DOC)
  child.cmd("Deckle open")
  local s = state()

  -- Contadores independentes do módulo: autocmds de teste nos dois buffers.
  child.lua(
    [[
      local src, preview = ...
      _G.fired = { src = 0, preview = 0 }
      vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = src,
        callback = function() _G.fired.src = _G.fired.src + 1 end,
      })
      vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = preview,
        callback = function() _G.fired.preview = _G.fired.preview + 1 end,
      })
    ]],
    { s.src_buf, s.buf }
  )
  local function fired()
    return child.lua_get("_G.fired")
  end

  -- 1. Um movimento no fonte: um evento no fonte, nenhum no preview.
  child.type_keys("j")
  eq(fired(), { src = 1, preview = 0 })
  eq(cursor(src_win()), 1)
  eq(cursor(s.win), s.map[1].preview_end - 1)

  -- 2. Entrar no preview: o Neovim entrega um `CursorMoved` na janela em que se entra, o
  -- único evento a mais. O fonte não se mexe.
  child.type_keys("<C-w>l")
  eq(fired(), { src = 1, preview = 1 })
  eq(cursor(src_win()), 1)

  -- 3. Um movimento no preview: um evento no preview, nenhum no fonte.
  child.type_keys("4G")
  eq(fired(), { src = 1, preview = 2 })
  eq(text_at(s.src_buf, cursor(src_win())), "primeiro paragrafo")

  -- 4. Voltar ao fonte: um evento no fonte. O preview não se mexe.
  child.type_keys("<C-w>h")
  eq(fired(), { src = 2, preview = 2 })
  eq(text_at(s.buf, cursor(s.win)), "primeiro paragrafo")

  -- 5. Vários movimentos: o total é a soma deles, sem eco.
  child.type_keys("j", "j", "j", "j")
  eq(fired(), { src = 6, preview = 2 })
  child.type_keys("<C-w>l")
  child.type_keys("k", "k", "k")
  eq(fired(), { src = 6, preview = 6 })
end

T["sincronia"]["a flag reentrante corta o loop quando o evento volta de forma síncrona"] = function()
  use_source(DOC)
  child.cmd("Deckle open")
  local s = state()

  -- Um ambiente hostil: toda vez que o módulo mexe numa janela que não é a atual, um
  -- terceiro redispara `CursorMoved` lá dentro, de forma síncrona. Sem a flag isso é um
  -- ping-pong sem fim; o limite de 50 existe para o teste falhar com número, e não travar.
  child.lua([[
    _G.injected = 0
    local original = vim.api.nvim_win_call
    vim.api.nvim_win_call = function(win, fn)
      if win == vim.api.nvim_get_current_win() or _G.injected >= 50 then
        return original(win, fn)
      end
      return original(win, function()
        local result = fn()
        _G.injected = _G.injected + 1
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0, modeline = false })
        return result
      end)
    end
  ]])

  -- Fonte -> preview: o módulo mexe numa janela alheia uma vez, e a injeção é uma só.
  child.type_keys("3G")
  eq(child.lua_get("_G.injected"), 1)
  eq(text_at(s.buf, cursor(s.win)), "primeiro paragrafo")

  -- Preview -> fonte.
  child.type_keys("<C-w>l")
  child.type_keys("9G")
  eq(child.lua_get("_G.injected"), 2)
  eq(text_at(s.src_buf, cursor(src_win())), "> citacao")
  eq(child.lua_get("_G.notes"), {})
end

-- ---------------------------------------------------------------------------------------
-- sync = "off"
-- ---------------------------------------------------------------------------------------

T["sincronia"]["sync = off não cria autocmd nenhum"] = function()
  child.lua([[require("deckle").setup({ sync = "off" })]])
  use_source(DOC)
  child.cmd("Deckle open")
  local s = state()

  eq(census().sync_autocmds, 0)
  -- Nenhum autocmd do deckle em `CursorMoved`, e o `User` que ouviria o render também não.
  eq(
    child.lua_get([[
      #vim.tbl_filter(function(au)
        return (au.group_name or ""):find("^deckle") ~= nil
          and (au.event == "CursorMoved" or au.event == "CursorMovedI")
      end, vim.api.nvim_get_autocmds({}))
    ]]),
    0
  )
  eq(
    child.lua_get([[
      #vim.tbl_filter(function(au)
        return (au.group_name or ""):find("^deckle_sync") ~= nil
      end, vim.api.nvim_get_autocmds({ event = "User" }))
    ]]),
    0
  )
  eq(child.lua_get([[require("deckle.sync").is_attached(_G.src)]]), false)

  -- E o preview não acompanha o fonte.
  child.type_keys("G")
  eq(cursor(src_win()), #DOC - 1)
  eq(cursor(s.win), 0)
  -- Nem o fonte o preview.
  child.type_keys("<C-w>l")
  child.type_keys("4G")
  eq(cursor(src_win()), #DOC - 1)
end

T["sincronia"]["sync = cursor registra três autocmds por preview aberto, num augroup só"] = function()
  use_source(DOC)
  child.cmd("Deckle open")
  local c = census()
  eq(c.sync_groups, 1)
  eq(c.sync_autocmds, 3)
  eq(child.lua_get([[require("deckle.sync").is_attached(_G.src)]]), true)
end

-- ---------------------------------------------------------------------------------------
-- Limpeza
-- ---------------------------------------------------------------------------------------

T["sincronia"]["fechar e reabrir não vaza autocmd de sync, por contagem"] = function()
  use_source(DOC)
  child.cmd("Deckle open")
  child.cmd("Deckle close")
  local floor = census()
  eq(floor.sync_autocmds, 0)

  for _ = 1, 5 do
    child.cmd("Deckle open")
    local open = census()
    eq(open.sync_autocmds, 3)
    eq(open.sync_groups, 1)
    child.cmd("Deckle close")
    eq(census(), floor)
  end
end

T["sincronia"]["fechar a janela por conta própria limpa os autocmds de sync"] = function()
  use_source(DOC)
  child.cmd("Deckle open")
  child.api.nvim_set_current_win(state().win)
  child.cmd("close")
  eq(census().sync_autocmds, 0)
  eq(child.lua_get([[require("deckle.sync").is_attached(_G.src)]]), false)

  -- E o preview reabre com a sincronia de volta.
  child.cmd("Deckle open")
  eq(census().sync_autocmds, 3)
end

T["sincronia"]["apagar o buffer fonte ou o de preview limpa tudo do deckle"] = function()
  use_source(DOC)
  child.cmd("Deckle open")
  child.cmd("bwipeout! " .. state().src_buf)
  eq(census().sync_autocmds, 0)
  eq(census().deckle_autocmds, 0)

  use_source(DOC)
  child.cmd("Deckle open")
  eq(census().sync_autocmds, 3)
  child.cmd("bwipeout! " .. state().buf)
  eq(census().sync_autocmds, 0)
  eq(census().deckle_autocmds, 0)
end

T["sincronia"]["depois de fechar, mover o cursor não mexe em nada e não dá erro"] = function()
  use_source(DOC)
  child.cmd("Deckle open")
  local s = state()
  child.cmd("Deckle close")
  child.type_keys("G")
  eq(child.lua_get("_G.notes"), {})
  eq(child.api.nvim_buf_is_valid(s.buf), true)
  eq(cursor(src_win()), #DOC - 1)
end

T["sincronia"]["`attach` e `detach` são idempotentes, e `attach` sem preview não faz nada"] = function()
  use_source(DOC)
  eq(child.lua_get([[require("deckle.sync").attach(_G.src)]]), false) -- sem preview aberto
  eq(census().sync_autocmds, 0)

  child.cmd("Deckle open")
  eq(child.lua_get([[require("deckle.sync").attach(_G.src)]]), true)
  eq(child.lua_get([[require("deckle.sync").attach(_G.src)]]), true)
  eq(census().sync_autocmds, 3)

  child.lua([[require("deckle.sync").detach(_G.src); require("deckle.sync").detach(_G.src)]])
  eq(census().sync_autocmds, 0)
end

-- ---------------------------------------------------------------------------------------
-- Gate 3: documento grande
-- ---------------------------------------------------------------------------------------

T["desempenho"] = new_set({ hooks = hooks })

T["desempenho"]["documento de 5000 linhas: mover o cursor nos dois lados custa poucos milissegundos"] = function()
  child.lua([==[
    -- 1000 seções de 5 linhas: título, branco, um parágrafo de duas linhas e branco.
    local lines = {}
    for i = 1, 1000 do
      lines[#lines + 1] = "# Secao " .. i
      lines[#lines + 1] = ""
      lines[#lines + 1] = "texto " .. i
      lines[#lines + 1] = "outro " .. i
      lines[#lines + 1] = ""
    end
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.filetype = "markdown"
    _G.src = vim.api.nvim_get_current_buf()
    _G.src_win = vim.api.nvim_get_current_win()
    vim.cmd("Deckle open")
  ]==])
  eq(child.lua_get("vim.api.nvim_buf_line_count(_G.src)"), 5000)
  local s = child.lua_get("require('deckle.preview').state(_G.src)")
  eq(#s.map, 2000)

  -- Cada movimento é uma mudança de cursor mais o `CursorMoved` que o dispara, dentro do
  -- próprio Neovim: o que se mede é o custo do módulo, não o da ida e volta de RPC.
  local result = child.lua(
    [==[
      local preview = ...
      local function run(win, buf, step)
        vim.api.nvim_set_current_win(win)
        local count = vim.api.nvim_buf_line_count(buf)
        local moves, line = 0, 1
        local started = vim.uv.hrtime()
        while line <= count do
          vim.api.nvim_win_set_cursor(win, { line, 0 })
          vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf, modeline = false })
          moves = moves + 1
          line = line + step
        end
        return (vim.uv.hrtime() - started) / 1e6 / moves, moves
      end
      local src_ms, src_moves = run(_G.src_win, _G.src, 7)
      local preview_ms, preview_moves = run(preview.win, preview.buf, 5)
      return {
        src_ms = src_ms,
        src_moves = src_moves,
        preview_ms = preview_ms,
        preview_moves = preview_moves,
      }
    ]==],
    { { win = s.win, buf = s.buf } }
  )
  eq(result.src_moves > 500, true)
  eq(result.preview_moves > 500, true)
  -- Na prática, dezenas de microssegundos; 5 ms é folga para a CI.
  eq(result.src_ms < 5, true)
  eq(result.preview_ms < 5, true)

  -- E o resultado está certo, não só rápido: o último movimento foi no preview, e o fonte
  -- foi parar na seção que o preview mostra.
  local preview_text = text_at(s.buf, cursor(s.win))
  local source_text = text_at(s.src_buf, cursor(src_win()))
  eq(preview_text:match("%d+"), source_text:match("%d+"))
end

-- ---------------------------------------------------------------------------------------
-- Gate 4: editar, re-renderizar, sincronizar de novo
-- ---------------------------------------------------------------------------------------

T["edição"] = new_set({ hooks = hooks })

T["edição"]["editar o fonte, re-renderizar e sincronizar de novo usa o mapa novo"] = function()
  child.lua([[require("deckle").setup({ debounce_ms = 20 })]])
  use_source({ "# a", "", "alvo um", "", "fim" })
  child.cmd("Deckle open")
  local before = state()
  child.type_keys("3G")
  eq(text_at(before.buf, cursor(before.win)), "alvo um")

  -- Dois parágrafos novos no topo: todo bloco desce 4 linhas do fonte.
  child.lua([[
    vim.api.nvim_buf_set_lines(_G.src, 0, 0, false, { "intro", "", "intro dois", "" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = _G.src })
  ]])
  wait_renders(2)

  local after = state()
  eq(#after.map, #before.map + 2)
  eq(after.map[#after.map].src_start, before.map[#before.map].src_start + 4)

  -- O alvo agora está na linha 7 (1-indexada). Com o mapa velho essa linha cairia em outro
  -- bloco; com o novo, cai no alvo.
  child.type_keys("gg")
  child.type_keys("7G")
  eq(text_at(src_buf(), cursor(src_win())), "alvo um")
  eq(text_at(after.buf, cursor(after.win)), "alvo um")

  -- O inverso, com o mapa novo.
  child.type_keys("<C-w>l")
  child.type_keys("gg")
  eq(text_at(src_buf(), cursor(src_win())), "intro")
  child.type_keys(("%dG"):format(after.map[#after.map].preview_start + 1))
  eq(text_at(src_buf(), cursor(src_win())), "fim")
end

T["edição"]["o re-render realinha o preview ao cursor do fonte, pelo mapa novo"] = function()
  use_source({ "# a", "", "alvo um", "", "fim" })
  child.cmd("Deckle open")

  child.lua([[vim.api.nvim_buf_set_lines(_G.src, 0, 0, false, { "intro", "", "intro dois", "" })]])
  -- O cursor está no alvo, que o texto novo empurrou para a linha 7 (1-indexada).
  child.api.nvim_win_set_cursor(src_win(), { 7, 0 })
  child.cmd("Deckle refresh")

  local s = state()
  eq(s.renders, 2)
  eq(text_at(s.buf, cursor(s.win)), "alvo um")
end

T["edição"]["um erro na sincronia não trava as seguintes nem vira ruído"] = function()
  use_source(DOC)
  child.cmd("Deckle open")
  local s = state()

  -- Força o erro: `winrestview` lança dentro do módulo.
  child.lua([[
    _G.original_winrestview = vim.fn.winrestview
    vim.fn.winrestview = function() error("boom") end
  ]])
  child.type_keys("3G")
  child.type_keys("5G")
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1) -- `notify_once`: um aviso, não um por movimento
  eq(notes[1].msg:find("scroll sync failed", 1, true) ~= nil, true)

  -- Passou o erro: a próxima movimentação sincroniza normalmente (a flag não ficou presa).
  child.lua([[vim.fn.winrestview = _G.original_winrestview]])
  child.type_keys("8G")
  eq(text_at(s.buf, cursor(s.win)):find("citacao", 1, true) ~= nil, true)
end

T["edição"]["dois fontes com preview: cada cursor mexe só no preview dele"] = function()
  child.lua([[
    local function make(text)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
      vim.bo[buf].filetype = "markdown"
      return buf
    end
    _G.a = make({ "# A", "", "a um", "", "a dois" })
    _G.b = make({ "# B", "", "b um", "", "b dois" })

    -- Em cima, B e o preview dele; embaixo, A e o preview dele.
    vim.api.nvim_set_current_buf(_G.a)
    _G.a_win = vim.api.nvim_get_current_win()
    require("deckle.preview").open(_G.a)
    vim.cmd("split")
    vim.api.nvim_set_current_buf(_G.b)
    _G.b_win = vim.api.nvim_get_current_win()
    require("deckle.preview").open(_G.b)
  ]])
  local pa = child.lua_get([[require("deckle.preview").state(_G.a)]])
  local pb = child.lua_get([[require("deckle.preview").state(_G.b)]])
  eq(child.lua_get("require('deckle.sync').is_attached(_G.a)"), true)
  eq(child.lua_get("require('deckle.sync').is_attached(_G.b)"), true)
  eq(child.lua_get("_G.census().sync_groups"), 2)

  -- Estamos no B: o cursor dele anda, o preview do A fica quieto.
  local a_cursor = cursor(pa.win)
  child.type_keys("G")
  eq(text_at(pb.buf, cursor(pb.win)), "b dois")
  eq(cursor(pa.win), a_cursor)

  -- E o contrário.
  local b_cursor = cursor(pb.win)
  child.api.nvim_set_current_win(child.lua_get("_G.a_win"))
  child.type_keys("G")
  eq(text_at(pa.buf, cursor(pa.win)), "a dois")
  eq(cursor(pb.win), b_cursor)
end

-- ---------------------------------------------------------------------------------------
-- Altura da janela
-- ---------------------------------------------------------------------------------------

T["alinhamento"] = new_set({ hooks = hooks })

T["alinhamento"]["o preview chega na mesma altura relativa que o cursor do fonte"] = function()
  use_source(identity_doc(200))
  child.cmd("Deckle open")
  local s = state()
  local win = src_win()

  -- Cursor na linha 100 (1-indexada), com a janela do fonte rolada para que ela fique mais
  -- abaixo do topo. Uma tecla faz o laço andar e entrega `CursorMoved`.
  child.lua([[vim.fn.winrestview({ topline = 90, lnum = 100 })]])
  child.type_keys("j")
  local src_view = view(win)
  eq(src_view.lnum, 101)
  eq(src_view.topline, 90)

  local preview_view = view(s.win)
  eq(preview_view.lnum, 101) -- mapa identidade: a mesma linha
  eq(preview_view.topline, 90) -- e na mesma altura: o topo também coincide

  -- Outra altura: o alinhamento acompanha.
  child.lua([[vim.fn.winrestview({ topline = 60, lnum = 80 })]])
  child.type_keys("j")
  eq(view(s.win).lnum, 81)
  eq(view(s.win).topline, 60)
end

T["alinhamento"]["o fonte chega na mesma altura relativa que o cursor do preview"] = function()
  use_source(identity_doc(200))
  child.cmd("Deckle open")
  local s = state()
  local win = src_win()

  child.type_keys("<C-w>l")
  child.lua([[vim.fn.winrestview({ topline = 120, lnum = 130 })]])
  child.type_keys("j")
  eq(view(s.win).lnum, 131)
  local src_view = view(win)
  eq(src_view.lnum, 131)
  eq(src_view.topline, 120)
end

T["alinhamento"]["perto do fim do documento a janela não deixa um vão embaixo"] = function()
  use_source(identity_doc(200))
  child.cmd("Deckle open")
  local s = state()
  local height = child.api.nvim_win_get_height(s.win)
  local count = child.api.nvim_buf_line_count(s.buf)

  -- Cursor numa das últimas linhas, no alto da janela do fonte: a mesma altura deixaria o
  -- preview com um vão, então a última página cheia é o limite.
  child.lua([[vim.fn.winrestview({ topline = 395, lnum = 398 })]])
  child.type_keys("j")
  eq(view(s.win).lnum, 399)
  eq(view(s.win).topline <= count - height + 1, true)
end

T["alinhamento"]["split = tab: o preview nasce alinhado e o preview move o fonte na outra aba"] = function()
  child.lua([[require("deckle").setup({ split = "tab" })]])
  use_source(identity_doc(200))
  local win = src_win()
  child.api.nvim_win_set_cursor(win, { 101, 0 })
  child.cmd("Deckle open")
  local s = state()

  -- O foco está na aba do preview, e o primeiro render o alinhou ao fonte da outra aba.
  eq(child.api.nvim_get_current_win(), s.win)
  eq(cursor(s.win), 100)

  child.type_keys("4j")
  eq(cursor(win), 104)
end

return T
