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
--- # Layout simplificado
---
--- O layout de texto do merman não roteia todo flowchart (aresta que cruza a borda de um
--- subgraph, traços diferentes que se cruzam). Nesses casos o crate desenha de novo sem o que não
--- sabe rotear e devolve, junto das linhas, um aviso de uma linha (`deckle_native.render` devolve
--- `lines, notice`). O desenho sai normalmente, e o aviso vai numa linha `DeckleCodeNote` logo
--- abaixo dele, **sem** o prefixo `mermaid:` (que é só da degradação: nada foi desenhado). O aviso
--- fica em `M.last_notice`.
---
--- # Linha mais larga que a janela
---
--- O `width` do `ctx` vai ao crate como **meta**: o merman tenta o perfil compacto quando o
--- layout passa dela, mas nunca corta (perderia dado). O que ainda sobrar fica inteiro, como
--- código: não se quebra nem se trunca uma linha de diagrama, e a janela de preview não tem
--- `wrap`, então ela rola na horizontal. Cortar desalinharia a caixa; reflow é coisa do merman.
---
--- # Cache
---
--- Diagrama grande custa 46 ms (V5) e o preview renderiza de novo a cada edição e a cada
--- mudança de largura, então o desenho fica guardado. A chave é o SHA-256 de (conteúdo do
--- bloco, largura, charset, `max_src_lines`, `diagram_ty`): as duas últimas mudam o resultado e
--- entram para a chave não servir um erro de "grande demais" depois de o limite subir.
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

--- Aviso completo (sem corte) do último desenho que saiu com o layout simplificado, ou `nil`.
--- Para teste e depuração.
---@type string|nil
M.last_notice = nil

--- A moldura já tem `mermaid` no rótulo, então a nota é curta: quando o bloco é estreito ela
--- perde o fim, não o começo.
local NOTE_PREFIX = "mermaid: "

-- ---------------------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------------------

---@class deckle.MermaidCacheEntry
---@field lines string[]|nil  o desenho, quando o render deu certo
---@field notice string|nil   o aviso de layout simplificado, quando o desenho o teve
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

--- Chama o crate. Devolve as linhas (e o aviso de layout simplificado, se houve), ou `nil` e a
--- mensagem do erro.
---@param mod deckle.NativeModule
---@param src string
---@param opts table
---@return string[]|nil lines
---@return string|nil err
---@return string|nil notice
local function call_native(mod, src, opts)
  local ok, result, notice = pcall(mod.render, src, opts)
  if not ok then
    return nil, vim.trim((tostring(result):gsub("%s+", " ")))
  end
  if type(result) ~= "table" or type(result[1]) ~= "string" then
    return nil, "the native renderer returned no lines"
  end
  if type(notice) ~= "string" or notice == "" then
    notice = nil
  end
  return result, nil, notice
end

--- Desenha o bloco: linhas de arte (e o aviso de layout simplificado), ou `nil` e o motivo
--- (curto para a nota, completo para `last_error`).
---@param block deckle.Block
---@param ctx deckle.RenderCtx
---@return string[]|nil lines
---@return string|nil short
---@return string|nil detail
---@return string|nil notice
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
  local max_lines = require("deckle.config").options.mermaid.max_src_lines
  local opts = {
    width = ctx.width,
    charset = ctx.charset,
    diagram_ty = type(block.diagram_ty) == "string" and block.diagram_ty or nil,
    max_src_lines = max_lines,
  }
  local src = table.concat(source, "\n")

  local key
  if #source <= max_lines then
    key = sha256.hex(
      table.concat({ opts.width, opts.charset, max_lines, opts.diagram_ty or "", src }, "\0")
    )
    local entry = recall(key)
    if entry then
      hits = hits + 1
      if entry.lines then
        return copy(entry.lines), nil, nil, entry.notice
      end
      return nil, entry.err
    end
    misses = misses + 1
  end

  local lines, err, notice = call_native(mod, src, opts)
  if key then
    remember(key, { lines = lines, err = err, notice = notice })
  end
  if not lines then
    return nil, err
  end
  return copy(lines), nil, nil, notice
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
  local ok, lines, short, detail, notice = pcall(draw, block, ctx)
  if not ok then
    lines, short, detail, notice = nil, "internal error", tostring(lines), nil
  end

  if lines then
    local marks = {}
    for row, line in ipairs(lines) do
      if line:find("%S") then
        marks[#marks + 1] = { row = row - 1, col = 0, end_col = #line, hl = "DeckleMermaid" }
      end
    end
    M.last_notice = notice
    if notice then
      -- O aviso vai abaixo do desenho, como a nota da degradação vai abaixo da moldura.
      local line = require("deckle.render.code").note_line(notice, ctx)
      lines[#lines + 1] = line
      marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #line, hl = "DeckleCodeNote" }
    end
    return lines, marks
  end

  M.last_error = detail or short
  return degrade(block, ctx, short or "unknown error")
end

return M
