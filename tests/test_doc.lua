-- Testes da documentação (fase 10): o `doc/deckle.txt` carrega, as tags batem, e o que o doc e o
-- README dizem do código é o que o código tem.
--
-- Nada aqui compara texto livre. Cada caso liga a documentação a uma fonte de verdade que muda
-- junto com o código: as chaves de `config.lua`, os grupos de `highlight.lua`, os subcomandos de
-- `init.lua`, os eventos de `preview.lua`, os alvos de `install.lua` e o piso de versão. Quem
-- acrescenta uma opção, um grupo ou um subcomando sem documentá-lo vê o teste dizer o quê.
--
-- A captura do README (com o Mermaid de verdade) depende do `.so` e é conferida em
-- `tests/native/test_docs_native.lua`.

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fn.fnamemodify(this_file, ":p:h")
local H = dofile(tests_dir .. "/doc_helpers.lua")

local doc_lines = vim.fn.readfile(H.doc_path)
local doc_text = table.concat(doc_lines, "\n")

local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    post_once = child.stop,
  },
})

-- ---------------------------------------------------------------------------------------
-- Apoio: tags
-- ---------------------------------------------------------------------------------------

---@param path string um arquivo `tags` do Vim
---@return table<string, true>
local function read_tags(path)
  local set = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    local name = line:match("^([^\t]+)\t")
    if name then
      set[name] = true
    end
  end
  return set
end

---@type { dir: string, defined: table<string, true> }|nil
local built = nil

--- Copia o `doc/deckle.txt` para um diretório novo e roda `:helptags` nele, para o checkout não
--- ganhar um `doc/tags`. Lança erro se o `:helptags` reclamar (tag duplicada, por exemplo).
---@return string dir diretório com `doc/deckle.txt` e `doc/tags`
---@return table<string, true> defined as tags que o doc define
local function build_tags()
  if not built then
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/doc", "p")
    vim.fn.writefile(doc_lines, dir .. "/doc/deckle.txt")
    vim.cmd("helptags " .. vim.fn.fnameescape(dir .. "/doc"))
    built = { dir = dir, defined = read_tags(dir .. "/doc/tags") }
  end
  return built.dir, built.defined
end

--- As tags da documentação do próprio Neovim: `|:checkhealth|`, `|nvim_set_hl()|` e afins são
--- referências válidas, e o `$VIMRUNTIME` é a fonte delas.
---@return table<string, true>
local function neovim_tags()
  return read_tags(vim.env.VIMRUNTIME .. "/doc/tags")
end

---@param tag string
---@return string|nil linha a linha do doc que define `tag`
---@return integer|nil lnum
local function line_defining(tag)
  for lnum, line in ipairs(doc_lines) do
    if line:find("*" .. tag .. "*", 1, true) then
      return line, lnum
    end
  end
  return nil, nil
end

-- ---------------------------------------------------------------------------------------
-- Gate: o doc carrega
-- ---------------------------------------------------------------------------------------

T["doc/deckle.txt"] = new_set()

T["doc/deckle.txt"]["`:helptags doc/` roda sem erro e gera as tags das seções"] = function()
  local _, defined = build_tags()
  for _, tag in ipairs({
    "deckle.txt",
    "deckle",
    "deckle-config",
    "deckle-commands",
    ":Deckle",
    "deckle-highlights",
    "deckle-layers",
    "deckle-install",
    "deckle-health",
    "deckle-limitations",
  }) do
    eq({ tag, defined[tag] }, { tag, true })
  end
end

T["doc/deckle.txt"]["`:help deckle` abre o doc, e o `:help` acha tags de formato difícil"] = function()
  local dir = build_tags()
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.lua([[vim.opt.rtp:append(...)]], { dir })

  child.cmd("help deckle")
  eq(child.lua_get([[vim.bo.filetype]]), "help")
  eq(child.lua_get([[vim.fn.expand("%:t")]]), "deckle.txt")

  -- Tag com ponto, com dois pontos e a de um grupo de highlight: o cursor cai na linha que a
  -- define.
  for _, tag in ipairs({ "deckle-config-native.path", ":Deckle-open", "hl-DeckleH1" }) do
    child.cmd("help " .. tag)
    local landed = child.lua_get([[vim.fn.getline(".")]])
    eq({ tag, landed:find("*" .. tag .. "*", 1, true) ~= nil }, { tag, true })
  end
end

T["doc/deckle.txt"]["toda referência `|tag|` aponta para uma tag que existe"] = function()
  local _, defined = build_tags()
  local neovim = neovim_tags()
  local missing = {}
  for lnum, line in ipairs(doc_lines) do
    for ref in line:gmatch("|([^%s|]+)|") do
      if not defined[ref] and not neovim[ref] then
        missing[#missing + 1] = ("linha %d: |%s|"):format(lnum, ref)
      end
    end
  end
  eq(missing, {})
end

T["doc/deckle.txt"]["não passa de 78 colunas e termina com a modeline do help"] = function()
  local long = {}
  for lnum, line in ipairs(doc_lines) do
    if vim.fn.strdisplaywidth(line) > 78 then
      long[#long + 1] = ("linha %d: %d colunas"):format(lnum, vim.fn.strdisplaywidth(line))
    end
  end
  eq(long, {})

  local last = doc_lines[#doc_lines]
  eq(last:find("vim:tw=78", 1, true) ~= nil, true)
  eq(last:find("ft=help", 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------------------
-- Configuração
-- ---------------------------------------------------------------------------------------

T["configuração"] = new_set()

T["configuração"]["toda opção de `setup()` tem tag `deckle-config-<caminho>`"] = function()
  local _, defined = build_tags()
  local keys = require("deckle.config").known_keys()
  local missing = {}
  for _, key in ipairs(keys[""]) do
    local tag = "deckle-config-" .. key
    if not defined[tag] then
      missing[#missing + 1] = tag
    end
    for _, sub in ipairs(keys[key] or {}) do
      if not defined[tag .. "." .. sub] then
        missing[#missing + 1] = tag .. "." .. sub
      end
    end
  end
  eq(missing, {})
end

T["configuração"]["o bloco de valores de fábrica do doc é idêntico a `defaults()`"] = function()
  local block = H.vimdoc_block(doc_lines, "deckle-config-defaults")
  eq(block ~= nil, true)
  local opts, err = H.captured_setup(block)
  eq(err, nil)
  eq(opts, require("deckle.config").defaults())
end

-- ---------------------------------------------------------------------------------------
-- Comandos, eventos, instalação, piso
-- ---------------------------------------------------------------------------------------

T["comandos"] = new_set()

T["comandos"]["todo subcomando de `:Deckle` tem tag `:Deckle-<nome>`"] = function()
  local _, defined = build_tags()
  local names = require("deckle").subcommands()
  eq(#names >= 6, true)
  local missing = {}
  for _, name in ipairs(names) do
    if not defined[":Deckle-" .. name] then
      missing[#missing + 1] = ":Deckle-" .. name
    end
  end
  eq(missing, {})
end

T["comandos"]["todo evento `User` que o preview emite tem tag"] = function()
  local _, defined = build_tags()
  local source = table.concat(vim.fn.readfile(H.repo_root .. "/lua/deckle/preview.lua"), "\n")
  local events = {}
  for name in source:gmatch('emit%("(%w+)"') do
    events[name] = true
  end
  -- A expressão acima é o que acha os eventos: se ela deixar de achar, o caso não prova nada.
  eq(vim.tbl_count(events) >= 3, true)
  local missing = {}
  for name in pairs(events) do
    if not defined[name] then
      missing[#missing + 1] = name
    end
  end
  eq(missing, {})
end

T["comandos"]["todo alvo de release do instalador aparece na tabela do doc e do README"] = function()
  local targets = require("deckle.install").release_targets()
  eq(#targets, 6)
  local readme = table.concat(vim.fn.readfile(H.readme_path), "\n")
  local missing = {}
  for _, target in ipairs(targets) do
    if not doc_text:find(target, 1, true) then
      missing[#missing + 1] = "doc: " .. target
    end
    if not readme:find(target, 1, true) then
      missing[#missing + 1] = "README: " .. target
    end
  end
  eq(missing, {})
end

T["comandos"]["o piso de versão do código é o do doc, do README e do ADR-0005"] = function()
  local plugin = table.concat(vim.fn.readfile(H.repo_root .. "/plugin/deckle.lua"), "\n")
  local health = table.concat(vim.fn.readfile(H.repo_root .. "/lua/deckle/health.lua"), "\n")
  local floor = plugin:match("Neovim (%d+%.%d+%.%d+) or newer")
  eq(floor ~= nil, true)
  eq(health:match('local MIN_NVIM = "([^"]+)"'), floor)

  local readme = table.concat(vim.fn.readfile(H.readme_path), "\n")
  local adr =
    table.concat(vim.fn.readfile(H.repo_root .. "/docs/adr/0005-piso-neovim-0-11.md"), "\n")
  eq(doc_text:find(floor, 1, true) ~= nil, true)
  eq(readme:find(floor, 1, true) ~= nil, true)
  eq(adr:find(floor, 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------------------

T["highlights"] = new_set()

--- O padrão de um grupo como o doc o escreve: `link: Title`, `bold`, `bold, italic`.
---@param def table
---@return string
local function describe(def)
  if def.link then
    return "link: " .. def.link
  end
  local attrs = {}
  for key, value in pairs(def) do
    if value == true then
      attrs[#attrs + 1] = key
    end
  end
  table.sort(attrs)
  return table.concat(attrs, ", ")
end

T["highlights"]["todo grupo de `highlight.lua` tem tag `hl-<grupo>` e o padrão certo"] = function()
  local _, defined = build_tags()
  local groups = require("deckle.highlight").groups
  eq(vim.tbl_count(groups) >= 18, true)

  local problems = {}
  for name, def in pairs(groups) do
    local tag = "hl-" .. name
    if not defined[tag] then
      problems[#problems + 1] = "sem tag: " .. tag
    else
      local line = line_defining(tag)
      if not line:find(name .. " (" .. describe(def) .. ")", 1, true) then
        problems[#problems + 1] = ("padrão de %s não é (%s): %s"):format(
          name,
          describe(def),
          line
        )
      end
    end
  end
  table.sort(problems)
  eq(problems, {})
end

-- ---------------------------------------------------------------------------------------
-- README e links
-- ---------------------------------------------------------------------------------------

T["readme"] = new_set()

T["readme"]["o bloco de configuração do README é idêntico a `defaults()`"] = function()
  local block = H.fence_under(vim.fn.readfile(H.readme_path), "Configuração", "lua")
  eq(block ~= nil, true)
  local opts, err = H.captured_setup(block)
  eq(err, nil)
  eq(opts, require("deckle.config").defaults())
end

T["readme"]["a captura tem o fonte e a saída, e a saída não está vazia"] = function()
  local source, capture = H.source_and_capture(vim.fn.readfile(H.readme_path), "Como fica")
  eq(source ~= nil and #source > 5, true)
  eq(capture ~= nil and #capture > 10, true)
  -- A captura mostra o desenho do Mermaid: sem ele ela contaria uma história que não é a da
  -- camada 1.
  eq(table.concat(capture, "\n"):find("Alice", 1, true) ~= nil, true)
end

--- Links relativos de um Markdown, com a linha de cada um. Nada de URL, âncora ou `mailto:`.
---@param lines string[]
---@return { lnum: integer, target: string }[]
local function relative_links(lines)
  local found = {}
  for lnum, line in ipairs(H.without_fences(lines)) do
    -- O que está entre crases é exemplo, não link: `![alt](caminho.png)`.
    for target in line:gsub("`[^`]*`", ""):gmatch("%]%(([^)%s]+)%)") do
      if not target:find("^%a[%w+.-]*:") and not target:find("^#") then
        found[#found + 1] = { lnum = lnum, target = (target:gsub("#.*$", "")) }
      end
    end
  end
  return found
end

T["readme"]["todo link relativo dos Markdown do projeto aponta para um arquivo que existe"] = function()
  local files = { "README.md", "CLAUDE.md", "examples/showcase.md" }
  vim.list_extend(files, vim.fn.glob(H.repo_root .. "/docs/**/*.md", false, true))
  local broken = {}
  for _, file in ipairs(files) do
    local path = vim.startswith(file, "/") and file or (H.repo_root .. "/" .. file)
    local dir = vim.fn.fnamemodify(path, ":h")
    for _, link in ipairs(relative_links(vim.fn.readfile(path))) do
      if link.target ~= "" and not vim.uv.fs_stat(vim.fs.normalize(dir .. "/" .. link.target)) then
        local shown = path:sub(#H.repo_root + 2)
        broken[#broken + 1] = ("%s:%d -> %s"):format(shown, link.lnum, link.target)
      end
    end
  end
  eq(broken, {})
end

return T
