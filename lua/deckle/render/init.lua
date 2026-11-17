--- IR -> linhas, marcas e mapa (fase 2).
---
--- Pega a lista de blocos de `deckle.parse` e devolve o texto do buffer de preview, os
--- highlights como marcas e o mapa `linha do preview -> linha do fonte`. Este módulo não toca
--- em buffer nem em janela: é função pura do IR e da largura (`preview.lua` é quem escreve).
---
--- As fases 3 (sync), 4 (tabela), 5 (código) e 7 (mermaid) dependem da forma descrita abaixo.
--- Mudar um campo aqui é mudar o contrato delas.
---
--- # Contrato de topo
---
--- ```lua
--- local result = require("deckle.render").render(ir, { width = 80, charset = "auto" })
--- result.lines  -- string[]: o texto, sem "\n"
--- result.marks  -- Mark[]: os highlights
--- result.map    -- MapEntry[]: um por bloco de topo, em ordem
--- ```
---
--- `opts.width` é a largura da janela de preview em células (default 80, mínimo
--- `MIN_WIDTH`). `opts.charset` é `"auto"`, `"unicode"` ou `"ascii"`; `"auto"` vira
--- `"unicode"`, salvo `$TERM` `linux` ou `dumb`, que viram `"ascii"` (heurística, não medida).
--- Entre dois blocos de topo há uma linha em branco. Bloco que renderiza zero linhas some, sem
--- linha em branco e sem entrada no mapa.
---
--- # Contrato de um módulo por tipo
---
--- Há um módulo por `kind` do IR em `lua/deckle/render/<kind>.lua`, e o dispatcher o carrega
--- sob demanda. Cada um devolve uma tabela com `render`:
---
--- ```lua
--- ---@param block deckle.Block  o bloco do IR, do tipo do módulo
--- ---@param ctx deckle.RenderCtx
--- ---@return string[] lines, deckle.Mark[] marks
--- function M.render(block, ctx) end
--- ```
---
--- Regras de quem escreve um módulo:
---
--- * `lines` não tem `"\n"`. Cada linha cabe em `ctx.width` células (medidas com
---   `vim.fn.strdisplaywidth`, nunca `#str`), exceto o que não pode ser partido (código,
---   diagrama, palavra mais larga que a linha de um caractere só).
--- * Lista vazia (`{}`) significa que o bloco não produz nada.
--- * O módulo renderiza o bloco como se estivesse na coluna 0 de uma janela de `ctx.width`
---   células. Recuo, borda e prefixo são do **contêiner** (`quote`, `list`), que renderiza os
---   filhos por `ctx.block` e prefixa as linhas com `deckle.render.util.prefix`. Nunca
---   adicione indentação por conta própria a partir de `ctx.indent`.
--- * Linha em branco antes ou depois do bloco é do contêiner/dispatcher, não do módulo.
--- * Marcas são só dados: o módulo não chama a API do Neovim.
--- * Se lançar erro, o dispatcher captura e o bloco vira uma linha de aviso (`DeckleError`);
---   o resto do documento renderiza. `M.last_error` guarda o motivo.
---
--- # Marcas
---
--- ```lua
--- { row = 0, col = 4, end_col = 9, hl = "DeckleStrong" }
--- ```
---
--- `row` é a linha dentro de `lines` (0-indexada, relativa ao bloco; no resultado de topo,
--- relativa ao documento). `col` e `end_col` são **bytes** 0-indexados com fim exclusivo, o que
--- `nvim_buf_set_extmark` espera, não células. Uma marca cobre uma linha só. `hl` é o nome do
--- grupo de highlight. `priority` é opcional e vai direto para o extmark. A ordem das marcas
--- no array não é garantida, e marcas se sobrepõem (negrito dentro de link).
---
--- # Mapa
---
--- ```lua
--- { preview_start = 0, preview_end = 3, src_start = 0, src_end = 2 }
--- ```
---
--- Um por bloco de topo, na ordem do documento (e portanto ordenado nos dois lados). Todos os
--- índices são 0-indexados com fim exclusivo. `preview_*` são linhas do buffer de preview e
--- `src_*` as do fonte (os `src_start`/`src_end` do bloco). As linhas em branco entre blocos
--- não pertencem a nenhum. O mapa é parcial de propósito: um bloco de 40 linhas pode mapear
--- para 6 do fonte, e a busca (fase 3) resolve para o bloco que contém a linha. Só blocos de
--- topo aparecem: os filhos de `quote` e `list` ficam dentro do intervalo do pai.

local util = require("deckle.render.util")

local M = {}

---@class deckle.Mark
---@field row integer        linha, 0-indexada, relativa às `lines` devolvidas
---@field col integer        byte inicial, 0-indexado
---@field end_col integer    byte final, exclusivo
---@field hl string          grupo de highlight
---@field priority integer|nil

---@class deckle.MapEntry
---@field preview_start integer  primeira linha do bloco no preview, 0-indexada
---@field preview_end integer    exclusiva
---@field src_start integer      `src_start` do bloco
---@field src_end integer        `src_end` do bloco, exclusivo

---@class deckle.RenderOpts
---@field width integer|nil                         default 80
---@field charset "auto"|"unicode"|"ascii"|nil     default `"auto"`

---@class deckle.RenderResult
---@field lines string[]
---@field marks deckle.Mark[]
---@field map deckle.MapEntry[]

--- O que cada módulo de tipo recebe junto do bloco.
---@class deckle.RenderCtx
---@field width integer     células disponíveis para o conteúdo do bloco, já descontado o prefixo dos contêineres; nunca menor que `MIN_WIDTH`
---@field charset "unicode"|"ascii"  já resolvido, nunca `"auto"`
---@field indent integer    células consumidas pelos contêineres ancestrais (informativo: largura da janela = `indent + width`)
---@field depth integer     profundidade de contêineres, 0 no topo
---@field list_level integer|nil  quantas listas envolvem o bloco (campo do módulo `list`)
---@field block fun(block: deckle.Block, consumed?: integer, extra?: table): string[], deckle.Mark[]

M.MIN_WIDTH = util.MIN_WIDTH
M.DEFAULT_WIDTH = 80

--- Motivo do último erro de módulo que o dispatcher engoliu, ou `nil`. Para teste e para
--- depuração: o erro não vai para `vim.notify`, que imprimiria a cada re-render.
---@type string|nil
M.last_error = nil

--- Módulo de cada tipo de bloco. Para as fases 4, 5 e 7 trocarem uma implementação, basta
--- reescrever o módulo: o nome e a assinatura ficam.
---@type table<string, string>
local MODULES = {
  heading = "deckle.render.heading",
  paragraph = "deckle.render.paragraph",
  list = "deckle.render.list",
  quote = "deckle.render.quote",
  rule = "deckle.render.rule",
  code = "deckle.render.code",
  table = "deckle.render.table",
  html = "deckle.render.html",
}

--- `"auto"` vira `"unicode"` ou `"ascii"`. O terminal do Linux (`TERM=linux`) e o `dumb` não
--- têm fonte confiável para bordas e marcadores; todo o resto assume que tem.
---@param charset string|nil
---@return "unicode"|"ascii"
function M.resolve_charset(charset)
  if charset == "unicode" or charset == "ascii" then
    return charset
  end
  local term = vim.env.TERM
  if term == "linux" or term == "dumb" then
    return "ascii"
  end
  return "unicode"
end

local render_block

--- Contexto de um bloco. `block` fecha sobre o próprio contexto: é como um contêiner pede o
--- render de um filho numa largura menor sem conhecer o dispatcher.
---@param fields table
---@return deckle.RenderCtx
local function new_ctx(fields)
  local ctx = fields
  ctx.block = function(block, consumed, extra)
    consumed = consumed or 0
    local child = {}
    for key, value in pairs(ctx) do
      child[key] = value
    end
    child.width = math.max(ctx.width - consumed, M.MIN_WIDTH)
    child.indent = ctx.indent + consumed
    child.depth = ctx.depth + 1
    for key, value in pairs(extra or {}) do
      child[key] = value
    end
    return render_block(block, new_ctx(child))
  end
  return ctx
end

--- Bloco que não pôde ser renderizado: uma linha de aviso no lugar dele.
---@param kind any
---@return string[] lines, deckle.Mark[] marks
local function degraded(kind)
  local line = string.format("[deckle: could not render %s block]", tostring(kind))
  return { line }, { { row = 0, col = 0, end_col = #line, hl = "DeckleError" } }
end

---@param block deckle.Block
---@param ctx deckle.RenderCtx
---@return string[] lines, deckle.Mark[] marks
function render_block(block, ctx)
  local name = type(block) == "table" and MODULES[block.kind] or nil
  if not name then
    M.last_error = "unknown block kind: " .. tostring(type(block) == "table" and block.kind)
    return degraded(type(block) == "table" and block.kind or type(block))
  end

  local ok, lines, marks = pcall(function()
    return require(name).render(block, ctx)
  end)
  if not ok or type(lines) ~= "table" then
    M.last_error = tostring(ok and "render did not return lines" or lines)
    return degraded(block.kind)
  end
  return lines, marks or {}
end

--- Renderiza o IR inteiro. Ver o contrato no topo do módulo.
---@param ir deckle.Block[]
---@param opts deckle.RenderOpts|nil
---@return deckle.RenderResult
function M.render(ir, opts)
  opts = opts or {}
  local ctx = new_ctx({
    width = math.max(opts.width or M.DEFAULT_WIDTH, M.MIN_WIDTH),
    charset = M.resolve_charset(opts.charset),
    indent = 0,
    depth = 0,
  })

  local lines, marks, map = {}, {}, {}
  for _, block in ipairs(ir or {}) do
    local block_lines, block_marks = render_block(block, ctx)
    if #block_lines > 0 then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      local start = #lines
      util.append(lines, marks, block_lines, block_marks)
      map[#map + 1] = {
        preview_start = start,
        preview_end = #lines,
        src_start = block.src_start,
        src_end = block.src_end,
      }
    end
  end
  return { lines = lines, marks = marks, map = map }
end

return M
