-- Apoio dos testes de `deckle.parse`: serialização de snapshot, validador dos intervalos
-- `src_start`/`src_end` (gate 4 da fase 1) e um gerador de documentos aleatórios.
--
-- Fica fora de `test_parse.lua` porque o fuzz roda dentro de um Neovim filho: se o
-- treesitter abortar o processo (e ele aborta com aninhamento fundo, ver docs/validation.md),
-- morre o filho e o teste falha com mensagem, em vez de derrubar a suíte inteira.

local M = {}

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
M.fixtures_dir = vim.fn.fnamemodify(this_file, ":p:h") .. "/fixtures"

---@param name string
---@return string[]
function M.read_fixture(name)
  return vim.fn.readfile(M.fixtures_dir .. "/" .. name .. ".md")
end

-- ---------------------------------------------------------------------------------------
-- Snapshot
-- ---------------------------------------------------------------------------------------

local KEY_LAST = { src_start = 1, src_end = 2 }

--- Ordem das chaves no snapshot: `kind` primeiro, `src_start`/`src_end` por último, o resto
--- em ordem alfabética. Estável, para o diff de um snapshot mostrar só o que mudou.
---@param a string
---@param b string
---@return boolean
local function key_before(a, b)
  if a == "kind" or b == "kind" then
    return a == "kind" and b ~= "kind"
  end
  local last_a, last_b = KEY_LAST[a], KEY_LAST[b]
  if last_a or last_b then
    if last_a and last_b then
      return last_a < last_b
    end
    return last_b ~= nil
  end
  return a < b
end

---@param t table
---@return boolean
local function is_array(t)
  for key in pairs(t) do
    if type(key) ~= "number" then
      return false
    end
  end
  return true
end

--- Lua válido e estável de um valor do IR. Tabelas curtas ficam numa linha só; buracos em
--- listas (o `align` das tabelas) saem como `nil`, e é como voltam no `dofile`.
---@param value any
---@param indent string|nil
---@return string
function M.serialize(value, indent)
  indent = indent or ""
  if type(value) ~= "table" then
    return vim.inspect(value)
  end

  local inner = indent .. "  "
  local items = {}
  if is_array(value) then
    local last = 0
    for key in pairs(value) do
      last = math.max(last, key)
    end
    for i = 1, last do
      items[i] = M.serialize(value[i], inner)
    end
  else
    local keys = vim.tbl_keys(value)
    table.sort(keys, key_before)
    for _, key in ipairs(keys) do
      items[#items + 1] = key .. " = " .. M.serialize(value[key], inner)
    end
  end

  if #items == 0 then
    return "{}"
  end
  local flat = "{ " .. table.concat(items, ", ") .. " }"
  if not flat:find("\n", 1, true) and #flat + #indent <= 90 then
    return flat
  end
  return "{\n" .. inner .. table.concat(items, ",\n" .. inner) .. ",\n" .. indent .. "}"
end

-- ---------------------------------------------------------------------------------------
-- Validação dos intervalos (gate 4)
-- ---------------------------------------------------------------------------------------

---@param s string
---@return boolean
local function is_blank(s)
  return s:match("^%s*$") ~= nil
end

--- Linha sem conteúdo: só espaço e marcadores de quote.
---@param s string
---@return boolean
local function is_marker_only(s)
  return s:match("^[%s>]*$") ~= nil
end

--- Tira prefixo de quote e de item (`> `, `- `, `1. `) do começo da linha.
---@param row string
---@return string
local function strip_prefix(row)
  local previous
  repeat
    previous = row
    row = row:gsub("^[%s>]+", "")
    row = row:gsub("^[-+*]%s+", "")
    row = row:gsub("^%d+[.)]%s+", "")
  until row == previous
  return row
end

---@param row string
---@return string
local function strip_quote(row)
  return (row:gsub("^[%s>]+", ""))
end

---@param s string
---@return string
local function normalize(s)
  return (vim.trim((s:gsub("%s+", " "))))
end

---@param spans table[]
---@param acc string[]
---@return string[]
local function leaf_texts(spans, acc)
  for _, span in ipairs(spans) do
    if span.kind == "text" or span.kind == "code" then
      acc[#acc + 1] = span.text
    elseif span.children then
      leaf_texts(span.children, acc)
    end
  end
  return acc
end

---@param s string
---@param suffix string
---@return boolean
local function ends_with(s, suffix)
  return suffix == "" or s:sub(-#suffix) == suffix
end

---@param s string
---@return boolean
local function is_fence(s)
  local opener = s:sub(1, 3)
  return opener == "```" or opener == "~~~"
end

--- Todo texto dos spans tem que existir no recorte do fonte. As barras invertidas saem do
--- fonte antes de comparar: `\|` e `\*` viram `|` e `*` no IR.
---@param report fun(msg: string)
---@param spans table[]
---@param rows string[]
local function check_text(report, spans, rows)
  local haystack = normalize(table.concat(rows, " ")):gsub("\\", "")
  for _, text in ipairs(leaf_texts(spans, {})) do
    for _, piece in ipairs(vim.split(text, "\n", { plain = true })) do
      piece = normalize(piece)
      if piece ~= "" and not haystack:find(piece, 1, true) then
        report(string.format("texto %q não está no trecho do fonte", piece))
      end
    end
  end
end

--- Linhas de `lines` (código ou html) contra o recorte: cada uma tem que ser o fim da linha
--- do fonte, porque o prefixo de quote/item foi removido.
---@param report fun(msg: string)
---@param lines string[]
---@param rows string[]
---@param from integer primeira linha do recorte que corresponde a `lines[1]`
local function check_lines(report, lines, rows, from)
  for i, line in ipairs(lines) do
    if not ends_with(rows[from + i - 1], line) then
      report(string.format("linha %d (%q) difere do fonte (%q)", i, line, rows[from + i - 1]))
    end
  end
end

---@param report fun(msg: string)
---@param b table
---@param rows string[]
local function check_kind(report, b, rows)
  local first, last = rows[1], rows[#rows]
  local kind = b.kind

  if kind == "heading" then
    local atx = #rows == 1 and strip_prefix(first):sub(1, 1) == "#"
    local setext = #rows >= 2 and strip_quote(last):match("^[=-]+%s*$") ~= nil
    if not (atx or setext) then
      report("heading sem `#` e sem sublinhado")
    end
    if b.level < 1 or b.level > 6 then
      report("level fora de 1..6")
    end
    check_text(report, b.spans, rows)
  elseif kind == "paragraph" then
    check_text(report, b.spans, rows)
  elseif kind == "rule" then
    local s = strip_quote(first):gsub("%s", "")
    if #rows ~= 1 or #s < 3 or s ~= string.rep(s:sub(1, 1), #s) or not s:find("^[-*_]") then
      report("rule que não é uma linha de `---`, `***` ou `___`")
    end
  elseif kind == "code" then
    local from, to = 1, #rows
    if is_fence(strip_prefix(first)) then
      from = 2
      if #rows >= 2 and is_fence(strip_prefix(last)) then
        to = #rows - 1
      end
    end
    if #b.lines ~= to - from + 1 then
      report(string.format("%d linhas de código para %d linhas de fonte", #b.lines, to - from + 1))
    else
      check_lines(report, b.lines, rows, from)
    end
  elseif kind == "html" then
    if #b.lines ~= #rows then
      report(string.format("%d linhas de html para %d linhas de fonte", #b.lines, #rows))
    else
      check_lines(report, b.lines, rows, 1)
    end
  elseif kind == "table" then
    if #rows ~= #b.rows + 2 then
      report(
        string.format("%d linhas de fonte para cabeçalho, delimitador e %d linhas", #rows, #b.rows)
      )
    end
    for i, row in ipairs(rows) do
      if not row:find("|", 1, true) then
        report("linha " .. i .. " da tabela sem `|`")
      end
    end
    for _, cell in ipairs(b.header) do
      check_text(report, cell, rows)
    end
    for _, row in ipairs(b.rows) do
      for _, cell in ipairs(row) do
        check_text(report, cell, rows)
      end
    end
  elseif kind == "quote" then
    if not first:find(">", 1, true) then
      report("quote cuja primeira linha não tem `>`")
    end
  end
end

--- Confere um intervalo `[start, stop)` contra o pai `[lo, hi)` e o irmão anterior.
---@param report fun(msg: string)
---@param node table
---@param lo integer
---@param hi integer
---@param previous_end integer
---@return boolean ok
local function check_range(report, node, lo, hi, previous_end)
  local s, e = node.src_start, node.src_end
  if type(s) ~= "number" or type(e) ~= "number" or s % 1 ~= 0 or e % 1 ~= 0 then
    report("src_start/src_end não são inteiros")
  elseif s < lo or e > hi or s >= e then
    report(string.format("intervalo fora de [%d, %d) ou vazio", lo, hi))
  elseif s < previous_end then
    report("sobrepõe o irmão anterior")
  else
    return true
  end
  return false
end

---@param c table
---@param blocks table[]
---@param lo integer
---@param hi integer
---@param path string
local function check_blocks(c, blocks, lo, hi, path)
  local previous_end = lo
  for i, b in ipairs(blocks) do
    local where = string.format(
      "%s/%d:%s[%s,%s)",
      path,
      i,
      tostring(b.kind),
      tostring(b.src_start),
      tostring(b.src_end)
    )
    local function report(msg)
      c.errors[#c.errors + 1] = where .. " " .. msg
    end

    if check_range(report, b, lo, hi, previous_end) then
      previous_end = b.src_end
      local rows = vim.list_slice(c.lines, b.src_start + 1, b.src_end)
      -- Nunca em branco nas pontas. Linha só de `>` no fim só é válida num contêiner, e só
      -- porque o último filho dele (um quote vazio aninhado) mora nela.
      local container = b.kind == "quote" or b.kind == "list"
      if
        is_blank(rows[1])
        or is_blank(rows[#rows])
        or (not container and #rows > 1 and is_marker_only(rows[#rows]))
      then
        report("o recorte começa ou termina numa linha sem conteúdo")
      end
      if c.strict then
        check_kind(report, b, rows)
      end

      if b.kind == "quote" then
        check_blocks(c, b.children, b.src_start, b.src_end, where)
      elseif b.kind == "list" then
        local item_end = b.src_start
        for j, item in ipairs(b.items) do
          local item_where = string.format(
            "%s.item%d[%s,%s)",
            where,
            j,
            tostring(item.src_start),
            tostring(item.src_end)
          )
          local function item_report(msg)
            c.errors[#c.errors + 1] = item_where .. " " .. msg
          end

          if check_range(item_report, item, b.src_start, b.src_end, item_end) then
            item_end = item.src_end
            if c.strict then
              local item_rows = vim.list_slice(c.lines, item.src_start + 1, item.src_end)
              local marker = strip_quote(item_rows[1])
              if
                not (
                  marker:match("^[-+*]%s")
                  or marker:match("^[-+*]$")
                  or marker:match("^%d+[.)]%s")
                )
              then
                item_report("item sem marcador de lista na primeira linha")
              end
              check_text(item_report, item.spans, item_rows)
            end
            check_blocks(c, item.children, item.src_start, item.src_end, item_where)
          end
        end
        local items = b.items
        if
          c.strict
          and #items > 0
          and (items[1].src_start ~= b.src_start or items[#items].src_end ~= b.src_end)
        then
          report("a lista não começa e termina onde o primeiro e o último item")
        end
      end
    end
  end
end

--- Confere os intervalos de todo bloco, item e filho de `blocks` contra o texto de `lines`:
--- inteiros, dentro do pai, sem sobrepor irmãos, sem linha vazia nas pontas. Com `strict`,
--- confere também que o recorte tem o formato do tipo do bloco e contém o seu texto.
---@param lines string[]
---@param blocks table[]
---@param strict boolean|nil
---@return string[] erros, vazio quando tudo bate
function M.check(lines, blocks, strict)
  local c = { lines = lines, strict = strict == true, errors = {} }
  check_blocks(c, blocks, 0, #lines, "")
  return c.errors
end

-- ---------------------------------------------------------------------------------------
-- Fuzz
-- ---------------------------------------------------------------------------------------

local FRAGMENTS = {
  "# título",
  "## título *com* `código`",
  "###### seis ##",
  "texto simples",
  "texto com **negrito**, *itálico* e [link](http://x.y)",
  "![alt](img.png) e [ref][r]",
  "[r]: http://ref.example",
  "- item",
  "- [ ] tarefa",
  "- [x] feita",
  "1. um",
  "2) dois",
  "* estrela",
  "+ mais",
  "> citação",
  ">",
  "```",
  "```lua",
  "~~~",
  "    indentado",
  "\tcom tab",
  "| a | b |",
  "|---|:-:|",
  "| 1 | 2 |",
  "| só um |",
  "---",
  "***",
  "===",
  "<div>",
  "</div>",
  "<!-- c -->",
  "日本語 😀 ñ",
  "\\",
  "`",
  "**",
  "[",
  "](",
  "|",
  "#",
  "-",
  "",
  "",
  "",
}

local PREFIXES = { "", "", "", "", "> ", "- ", "  ", "> > ", "- > ", "   ", "1. " }

--- Gerador congruencial: independe do estado global de `math.random`.
---@param seed integer
---@return fun(n: integer): integer
local function rng(seed)
  local state = seed
  return function(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return (math.floor(state / 65536) % n) + 1
  end
end

--- Parseia `lines` e devolve o que deu errado: lançou, engoliu um erro (caiu no caminho
--- cru sem precisar) ou devolveu intervalos incoerentes.
---@param lines string[]
---@return string[]
local function problems_for(lines)
  local parse = require("deckle.parse")
  local ok, blocks = pcall(parse.parse_lines, lines)
  if not ok then
    return { "lançou: " .. tostring(blocks) }
  end
  local problems = {}
  if parse.last_error then
    problems[1] = "erro engolido: " .. parse.last_error
  end
  vim.list_extend(problems, M.check(lines, blocks, false))
  return problems
end

--- Parseia cada documento de `docs` e devolve as falhas, uma string por documento ruim.
---@param docs string[][]
---@return string[]
function M.smoke(docs)
  local failures = {}
  for index, lines in ipairs(docs) do
    local problems = problems_for(lines)
    if #problems > 0 then
      failures[#failures + 1] = string.format(
        "documento %d:\n%s\n--\n%s",
        index,
        table.concat(lines, "\n"),
        table.concat(problems, "\n")
      )
    end
  end
  return failures
end

--- `count` documentos aleatórios a partir de `seed`, passados por `smoke`.
---@param count integer
---@param seed integer
---@return string[]
function M.fuzz(count, seed)
  local next_int = rng(seed)
  local docs = {}
  for doc = 1, count do
    local lines = {}
    for i = 1, next_int(25) do
      lines[i] = PREFIXES[next_int(#PREFIXES)] .. FRAGMENTS[next_int(#FRAGMENTS)]
    end
    docs[doc] = lines
  end
  return M.smoke(docs)
end

return M
