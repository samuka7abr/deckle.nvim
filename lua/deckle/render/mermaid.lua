--- Render de `code` com info string `mermaid` (fase 7): camada 1 da ADR-0004.
---
--- O dispatcher (`deckle.render`) manda para cá todo bloco `code` com `lang == "mermaid"`
--- (minúsculo, como o Mermaid e o GitHub escrevem; é o que o `parse.lua` entrega, que guarda só
--- a primeira palavra da info string). O módulo pede o desenho ao `deckle_native` e devolve as
--- linhas de arte, Unicode ou ASCII conforme o `charset` do `ctx`.
---
--- # Degradação
---
--- Qualquer falha vira, **só para aquele bloco**, o bloco de código com moldura que o
--- `deckle.render.code` desenha (rótulo `mermaid` na borda), mais uma nota discreta de uma
--- linha abaixo dele (`DeckleCodeNote`):
---
--- * módulo nativo ausente, não carregado ou desligado (`native.enabled = false`): camada 0;
--- * erro do render: sintaxe inválida, diagrama grande demais (`mermaid.max_src_lines`), tipo
---   que o renderer de texto não cobre (`pie`, `c4`...);
--- * erro inesperado deste módulo.
---
--- O bloco e a nota são do `render/code.lua`: este módulo só lhe entrega `lang`, `lines` e
--- `note` (o contrato que a fase 5 fixou). É ele quem corta a nota na largura do bloco, com
--- reticências, e quem não desenha nada para um bloco sem linhas: um `mermaid` vazio some do
--- preview, como qualquer cerca vazia. O motivo completo, sem corte, fica em `M.last_error`.
---
--- # Desenho simplificado
---
--- Há uma falha que **não** degrada o bloco: o `merman` não roteia as arestas que cruzam a borda
--- de um `subgraph` (e de certos estados compostos), e o crate então desenha o diagrama sem as
--- caixas deles (o fallback de achatamento, `docs/validation.md` V11). O bloco continua sendo
--- arte, e uma nota discreta (`DeckleCodeNote`) logo abaixo dela avisa que o desenho não é
--- fiel: `mermaid: layout simplified (subgraphs flattened)`. O que o crate achatou vem do
--- `render_ex` do módulo nativo; um módulo mais antigo, que só tem `render`, nunca simplifica.
--- O motivo (a mensagem do merman) fica em `M.last_simplified`.
---
--- # Linha mais larga que a janela
---
--- O `width` do `ctx` vai ao crate como **meta**: o merman tenta o perfil compacto quando o
--- layout passa dela, mas nunca corta (perderia dado). O que ainda sobrar fica inteiro, como
--- código: não se quebra nem se trunca uma linha de diagrama, e a janela de preview não tem
--- `wrap`, então ela rola na horizontal. Cortar desalinharia a caixa; reflow é coisa do merman.
---
--- # Cor
---
--- Com `mermaid.colors` ligado (o padrão) e `charset = "unicode"`, o crate desenha em TrueColor
--- (`opts.color = true`) e devolve só as cores que o diagrama pediu (`classDef`, `style`,
--- `linkStyle`, `box rgb`, `rect rgb`): as cores de tema do merman são tiradas no Rust. Este
--- módulo passa as linhas por `deckle.render.ansi`, que as devolve **sem nenhum escape** e com
--- as marcas de cor (grupos de highlight criados sob demanda). O texto sem cor própria continua
--- em `DeckleMermaid`. Com `colors = false` ou `charset = "ascii"` a saída é a de sempre.
---
--- # Cache
---
--- Diagrama grande custa 46 ms (V5) e o preview renderiza de novo a cada edição e a cada
--- mudança de largura, então o desenho fica guardado. A chave é o SHA-256 de (conteúdo do
--- bloco, largura, charset, `max_src_lines`, `diagram_ty`, se tem cor): as três últimas mudam o
--- resultado e entram para a chave não servir um erro de "grande demais" depois de o limite
--- subir, nem um desenho colorido depois de `mermaid.colors` ser desligado.
---
--- LRU simples com limite de `M.cache_limit` entradas. Guarda também o erro do render, que é
--- determinístico para a mesma chave e tão caro de recalcular quanto um sucesso. **Não** guarda
--- "nativo indisponível", que é estado da sessão e não do diagrama. Bloco com mais linhas que
--- `max_src_lines` nem entra no cache (o crate o recusa antes do layout, de graça), para o hash
--- não custar mais do que o erro que ele evitaria.

local native = require("deckle.native")
local sha256 = require("deckle.sha256")

local M = {}

--- Quantos desenhos o cache guarda antes de descartar o menos recente.
---@type integer
M.cache_limit = 64

--- Motivo completo da última degradação (a nota é cortada na largura), ou `nil`. Para teste e
--- depuração.
---@type string|nil
M.last_error = nil

--- Mensagem do merman que motivou o desenho simplificado mais recente, ou `nil` se o último
--- desenho veio inteiro. Para teste e depuração.
---@type string|nil
M.last_simplified = nil

--- A moldura já tem `mermaid` no rótulo, então a nota é curta: quando o bloco é estreito ela
--- perde o fim, não o começo.
local NOTE_PREFIX = "mermaid: "

-- ---------------------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------------------

---@class deckle.MermaidDrawing
---@field lines string[]          o desenho, sem nenhum escape
---@field marks deckle.Mark[]     as cores do diagrama (vazio sem `mermaid.colors` ou sem estilo)
---@field simplified string|nil  o que o crate achatou (`"subgraphs"`), ou `nil` se o desenho é fiel
---@field cause string|nil       a mensagem do merman que motivou a simplificação

---@class deckle.MermaidCacheEntry
---@field drawing deckle.MermaidDrawing|nil  o desenho, quando o render deu certo
---@field err string|nil      a mensagem do crate, quando deu erro
---@field tick integer        ordem de uso, para o LRU

---@type table<string, deckle.MermaidCacheEntry>
local cache = {}
local size, tick, hits, misses = 0, 0, 0, 0

--- Contadores do cache. `hits` conta consultas respondidas pelo cache; `misses`, consultas que
--- foram ao crate. Blocos que não passam pelo cache (nativo indisponível, grande demais) não
--- entram em nenhum dos dois.
---@return { hits: integer, misses: integer, size: integer, limit: integer }
function M.cache_stats()
  return { hits = hits, misses = misses, size = size, limit = M.cache_limit }
end

--- Esvazia o cache e zera os contadores. Para teste.
function M.cache_clear()
  cache, size, tick, hits, misses = {}, 0, 0, 0, 0
end

local function evict_oldest()
  local oldest_key, oldest_tick
  for key, entry in pairs(cache) do
    if not oldest_tick or entry.tick < oldest_tick then
      oldest_key, oldest_tick = key, entry.tick
    end
  end
  if oldest_key then
    cache[oldest_key] = nil
    size = size - 1
  end
end

---@param key string
---@param entry deckle.MermaidCacheEntry
local function remember(key, entry)
  tick = tick + 1
  entry.tick = tick
  if not cache[key] then
    size = size + 1
  end
  cache[key] = entry
  while size > math.max(M.cache_limit, 0) do
    evict_oldest()
  end
end

---@param key string
---@return deckle.MermaidCacheEntry|nil
local function recall(key)
  local entry = cache[key]
  if entry then
    tick = tick + 1
    entry.tick = tick
  end
  return entry
end

-- ---------------------------------------------------------------------------------------
-- Desenho
-- ---------------------------------------------------------------------------------------

--- Cópia rasa: o cache entrega a mesma tabela a todo render, e o chamador não pode alterá-la.
---@param lines string[]
---@return string[]
local function copy(lines)
  return vim.list_slice(lines, 1, #lines)
end

--- As marcas de cor ganham do `DeckleMermaid` (que cobre a linha toda, com a prioridade padrão do
--- extmark, 4096): `fg` e `bg` do diagrama sobrepõem o `Special` de base.
local COLOR_PRIORITY = 4100

--- Tira os escapes SGR das linhas que o crate devolveu em TrueColor e as transforma em marcas.
---
--- Quem entende o SGR é `deckle.render.ansi` (`parse(lines) -> clean_lines, marks`). Se ele não
--- existe ou falha, o desenho sai sem cor: os escapes são tirados com um `gsub`, e nenhum
--- escape chega ao buffer. Linhas sem escape (diagrama sem estilo) nem passam por ele.
---@param lines string[]
---@return string[] clean, deckle.Mark[] marks
local function split_colors(lines)
  local has_escape = false
  for _, line in ipairs(lines) do
    if line:find("\27", 1, true) then
      has_escape = true
      break
    end
  end
  if not has_escape then
    return lines, {}
  end

  local ok, ansi = pcall(require, "deckle.render.ansi")
  if ok and type(ansi) == "table" and type(ansi.parse) == "function" then
    local parsed, clean, marks = pcall(ansi.parse, lines)
    if parsed and type(clean) == "table" then
      for _, mark in ipairs(marks or {}) do
        mark.priority = mark.priority or COLOR_PRIORITY
      end
      return clean, marks or {}
    end
  end

  local clean = {}
  for i, line in ipairs(lines) do
    -- `ESC [ <números e ;> m`: o que o merman emite. Qualquer outro escape não é nosso.
    clean[i] = (line:gsub("\27%[[%d;:]*m", ""))
  end
  return clean, {}
end

--- Chama o crate. Devolve o desenho, ou `nil` e a mensagem do erro.
---
--- Usa `render_ex` (`{ lines, simplified?, cause? }`) quando o módulo a tem, e `render` (só as
--- linhas) quando não: um módulo de antes do fallback de achatamento nunca simplifica.
---@param mod deckle.NativeModule
---@param src string
---@param opts table
---@return deckle.MermaidDrawing|nil drawing
---@return string|nil err
local function call_native(mod, src, opts)
  local ok, result = pcall(mod.render_ex or mod.render, src, opts)
  if not ok then
    return nil, vim.trim((tostring(result):gsub("%s+", " ")))
  end
  local lines, simplified, cause = result, nil, nil
  if type(result) == "table" and result.lines ~= nil then
    lines, simplified, cause = result.lines, result.simplified, result.cause
  end
  if type(lines) ~= "table" or type(lines[1]) ~= "string" then
    return nil, "the native renderer returned no lines"
  end
  local marks = {}
  if opts.color then
    lines, marks = split_colors(lines)
  end
  return {
    lines = lines,
    marks = marks,
    simplified = type(simplified) == "string" and simplified or nil,
    cause = type(cause) == "string" and cause or nil,
  }
end

--- Cópia do desenho para entregar ao chamador: o cache guarda o original.
---@param drawing deckle.MermaidDrawing
---@return deckle.MermaidDrawing
local function copy_drawing(drawing)
  local marks = {}
  for i, mark in ipairs(drawing.marks) do
    marks[i] = {
      row = mark.row,
      col = mark.col,
      end_col = mark.end_col,
      hl = mark.hl,
      priority = mark.priority,
    }
  end
  return {
    lines = copy(drawing.lines),
    marks = marks,
    simplified = drawing.simplified,
    cause = drawing.cause,
  }
end

--- Desenha o bloco: o desenho, ou `nil` e o motivo (curto para a nota, completo para
--- `last_error`).
---@param block deckle.Block
---@param ctx deckle.RenderCtx
---@return deckle.MermaidDrawing|nil drawing
---@return string|nil short
---@return string|nil detail
local function draw(block, ctx)
  local mod = native.get()
  if not mod then
    local status = native.status()
    if not status.enabled then
      return nil, "native.enabled is false", status.reason
    end
    return nil, "native module unavailable (:checkhealth deckle)", status.reason
  end

  local source = block.lines or {}
  local options = require("deckle.config").options.mermaid
  local max_lines = options.max_src_lines
  local opts = {
    width = ctx.width,
    charset = ctx.charset,
    diagram_ty = type(block.diagram_ty) == "string" and block.diagram_ty or nil,
    max_src_lines = max_lines,
    -- Cor só com Unicode: em ASCII (`TERM=linux`, `dumb`) a saída é a de sempre, texto puro. A
    -- chave não existe quando não há cor, e o crate trata a ausência como `false`.
    color = (options.colors and ctx.charset ~= "ascii") or nil,
  }
  local src = table.concat(source, "\n")

  local key
  if #source <= max_lines then
    key = sha256.hex(table.concat({
      opts.width,
      opts.charset,
      max_lines,
      opts.diagram_ty or "",
      opts.color and "color" or "plain",
      src,
    }, "\0"))
    local entry = recall(key)
    if entry then
      hits = hits + 1
      if entry.drawing then
        return copy_drawing(entry.drawing)
      end
      return nil, entry.err
    end
    misses = misses + 1
  end

  local drawing, err = call_native(mod, src, opts)
  if key then
    remember(key, { drawing = drawing, err = err })
  end
  if not drawing then
    return nil, err
  end
  return copy_drawing(drawing)
end

-- ---------------------------------------------------------------------------------------
-- Degradação
-- ---------------------------------------------------------------------------------------

--- A mensagem do crate começa quase sempre com `mermaid ` (`mermaid parse error: ...`), e a
--- nota já diz que é do mermaid. Uma linha só: quebra e tabulação viram espaço.
---@param reason string
---@return string
local function tidy(reason)
  local text = vim.trim((reason:gsub("%s+", " ")))
  text = text:gsub("^mermaid ", "")
  return text
end

--- O bloco como código com moldura, e a nota de por que não virou desenho. Quem corta a nota na
--- largura é o `render/code.lua`.
---@param block deckle.Block
---@param ctx deckle.RenderCtx
---@param short string
---@return string[] lines, deckle.Mark[] marks
local function degrade(block, ctx, short)
  return require("deckle.render.code").render({
    kind = "code",
    lang = "mermaid",
    lines = block.lines,
    note = NOTE_PREFIX .. tidy(short),
    src_start = block.src_start,
    src_end = block.src_end,
  }, ctx)
end

-- ---------------------------------------------------------------------------------------
-- Contrato de módulo de tipo
-- ---------------------------------------------------------------------------------------

---@param block deckle.Block  `kind = "code"`, `lang = "mermaid"`
---@param ctx deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function M.render(block, ctx)
  local ok, drawing, short, detail = pcall(draw, block, ctx)
  if not ok then
    drawing, short, detail = nil, "internal error", tostring(drawing)
  end

  if drawing then
    local lines, marks = drawing.lines, {}
    for row, line in ipairs(lines) do
      if line:find("%S") then
        marks[#marks + 1] = { row = row - 1, col = 0, end_col = #line, hl = "DeckleMermaid" }
      end
    end
    -- As cores do diagrama vão por cima do `DeckleMermaid`, que continua sendo o de todo texto
    -- sem cor própria.
    vim.list_extend(marks, drawing.marks)
    M.last_simplified = drawing.cause
    if drawing.simplified then
      -- O desenho é arte, mas não é fiel: a nota diz isso, na largura do bloco.
      local note = require("deckle.render.code").truncate(
        ("%slayout simplified (%s flattened)"):format(NOTE_PREFIX, drawing.simplified),
        ctx.width,
        ctx.charset
      )
      lines[#lines + 1] = note
      marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #note, hl = "DeckleCodeNote" }
    end
    return lines, marks
  end

  M.last_error = detail or short
  return degrade(block, ctx, short or "unknown error")
end

return M
