-- Apoio dos testes de documentação (fase 10): caminhos, leitura do README e do `doc/deckle.txt`
-- e as duas extrações que ligam a documentação ao código, o bloco cercado de um Markdown e o
-- bloco de exemplo (`>lua ... <`) de um vimdoc.
--
-- Fica fora de `test_doc.lua` porque `tests/native/test_docs_native.lua` usa as mesmas
-- extrações (a captura do README, comparada com o render de verdade).

local M = {}

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))

M.repo_root = vim.fn.fnamemodify(this_file, ":p:h:h")
M.doc_path = M.repo_root .. "/doc/deckle.txt"
M.readme_path = M.repo_root .. "/README.md"
M.showcase_path = M.repo_root .. "/examples/showcase.md"

--- Largura, em colunas, da janela em que a captura do README foi gerada.
M.CAPTURE_WIDTH = 60

---@param relative string caminho a partir da raiz do repositório
---@return string[]
function M.read(relative)
  return vim.fn.readfile(M.repo_root .. "/" .. relative)
end

---@class deckle.test.Fence
---@field lang string        o info string da cerca (`""` sem ele)
---@field lines string[]     o conteúdo, sem as cercas
---@field heading string|nil o último título (`#`) visto antes da cerca
---@field start integer      linha da cerca de abertura, 1-indexada

--- Os blocos cercados de um Markdown, na ordem. Uma cerca fecha com a mesma quantidade de crases
--- ou mais, então um bloco de quatro crases pode conter um de três. Título dentro de uma cerca
--- não é título.
---@param lines string[]
---@return deckle.test.Fence[]
function M.fences(lines)
  local blocks, heading = {}, nil
  local i = 1
  while i <= #lines do
    local ticks, info = lines[i]:match("^(`+)(.*)$")
    if ticks and #ticks >= 3 then
      local body = {}
      local j = i + 1
      while j <= #lines do
        local close = lines[j]:match("^(`+)%s*$")
        if close and #close >= #ticks then
          break
        end
        body[#body + 1] = lines[j]
        j = j + 1
      end
      blocks[#blocks + 1] = { lang = vim.trim(info), lines = body, heading = heading, start = i }
      i = j + 1
    else
      heading = lines[i]:match("^#+%s+(.-)%s*$") or heading
      i = i + 1
    end
  end
  return blocks
end

--- As linhas de um Markdown com o que está dentro de cercas (e as cercas) em branco: sobra só a
--- prosa. O número de linhas não muda.
---@param lines string[]
---@return string[]
function M.without_fences(lines)
  local out = vim.deepcopy(lines)
  for _, block in ipairs(M.fences(lines)) do
    for lnum = block.start, block.start + #block.lines + 1 do
      out[lnum] = ""
    end
  end
  return out
end

--- A primeira cerca com a linguagem `lang` depois do título `heading`.
---@param lines string[]
---@param heading string
---@param lang string
---@return string[]|nil
function M.fence_under(lines, heading, lang)
  for _, block in ipairs(M.fences(lines)) do
    if block.heading == heading and block.lang == lang then
      return block.lines
    end
  end
  return nil
end

--- A segunda cerca (sem linguagem) depois do título `heading`, que é a captura do render: a
--- primeira, `markdown`, é o fonte dela.
---@param lines string[]
---@param heading string
---@return string[]|nil source, string[]|nil capture
function M.source_and_capture(lines, heading)
  local source, capture
  for _, block in ipairs(M.fences(lines)) do
    if block.heading == heading then
      if block.lang == "markdown" and not source then
        source = block.lines
      elseif block.lang == "" and source and not capture then
        capture = block.lines
      end
    end
  end
  return source, capture
end

--- O bloco de exemplo `>lua ... <` que vem logo depois da linha que define `tag` num vimdoc,
--- sem o recuo de quatro espaços. Procura nas quatro linhas seguintes.
---@param lines string[]
---@param tag string
---@return string[]|nil
function M.vimdoc_block(lines, tag)
  for i, line in ipairs(lines) do
    if line:find("*" .. tag .. "*", 1, true) then
      for j = i + 1, math.min(i + 4, #lines) do
        if lines[j]:match(">lua%s*$") then
          local body = {}
          for k = j + 1, #lines do
            if lines[k]:match("^<") then
              return body
            end
            body[#body + 1] = (lines[k]:gsub("^    ", ""))
          end
          return nil
        end
      end
      return nil
    end
  end
  return nil
end

--- Executa um bloco `require("deckle").setup({ ... })` sem carregar o plugin e devolve a tabela
--- que ele passaria ao `setup()`.
---@param block string[]
---@return table|nil opts, string|nil err
function M.captured_setup(block)
  local chunk, err = loadstring(table.concat(block, "\n"))
  if not chunk then
    return nil, err
  end
  local captured
  setfenv(chunk, {
    require = function()
      return {
        setup = function(opts)
          captured = opts
        end,
      }
    end,
  })
  local ok, run_err = pcall(chunk)
  if not ok then
    return nil, tostring(run_err)
  end
  return captured
end

--- Tira o espaço do fim de cada linha: o editor de quem mexe no README pode tirá-lo, e o
--- render também o deixa (o fluxograma do merman acaba em espaços).
---@param lines string[]
---@return string[]
function M.rtrim(lines)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = (line:gsub("%s+$", ""))
  end
  return out
end

return M
