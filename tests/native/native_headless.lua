-- Teste de regressao de V2.2: o `.so` em Rust, carregado dentro do Neovim, devolve erro
-- capturavel e o processo SOBREVIVE.
--
-- Roda com `nvim --headless -u NONE -l` (ver scripts/test-native.sh), nao com o mini.test: o
-- que se prova aqui e o exit code do processo, e um crash do nvim nao e uma falha que o
-- mini.test consiga reportar. O nome do arquivo nao comeca com `test_` de proposito, para a
-- suite de Lua da CI nao tentar rodar isto sem o `.so`.
--
-- Falha com `os.exit(1)`. Exit 134 e o nvim abortando, e quem avalia isso e o shell script.

local failures = {}

local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
    failures[#failures + 1] = name
  end
end

--- Chama `fn` com pcall e exige que ela falhe com uma mensagem legivel: string de uma linha,
--- sem traceback (se o Rust devolvesse o `Err` cru, o mlua entregaria userdata com traceback).
local function expect_error(name, fn, pattern)
  local ok, err = pcall(fn)
  check(name .. " raises", not ok, "pcall succeeded")
  check(name .. " error is a string", type(err) == "string", type(err))
  local msg = tostring(err)
  check(name .. " message", msg:find(pattern, 1, true) ~= nil, msg)
  check(
    name .. " is one clean line",
    not msg:find("\n", 1, true) and not msg:find("traceback", 1, true),
    msg
  )
  return msg
end

-- 1. O `.so` carrega. Um `.so` ausente ou velho nao pode passar por sucesso.
local loaded, native = pcall(require, "deckle_native")
check("require deckle_native", loaded, native)
if not loaded then
  print("(rode `make native` antes; scripts/test-native.sh faz isso)")
  os.exit(1)
end

check("exports render", type(native.render) == "function")
check("exports supported_types", type(native.supported_types) == "function")
check("exports version", type(native.version) == "function")

-- 2. Caminho feliz.
local lines = native.render("flowchart TD\n  A --> B", { width = 80, charset = "unicode" })
check("render returns a table", type(lines) == "table")
check("render returns string lines", type(lines[1]) == "string" and #lines > 3)
check("unicode charset draws boxes", table.concat(lines, "\n"):find("┌", 1, true) ~= nil)

local ascii = native.render("flowchart TD\n  A --> B", { width = 80, charset = "ascii" })
check("ascii charset has no unicode", not table.concat(ascii, "\n"):find("[\128-\255]"))

local no_opts = native.render("flowchart TD\n  A --> B")
check("opts is optional", #no_opts > 3)

local typed = native.render("sequenceDiagram\n  A->>B: hi", { diagram_ty = "sequence" })
check("diagram_ty accepted", #typed > 3)

local types = native.supported_types()
check("supported_types has 15 entries", #types == 15, #types)
check("version is a string", type(native.version()) == "string" and native.version() ~= "")

-- 3. Erros capturaveis por pcall: o coracao do gate. Cada um e um `Err` do Rust.
expect_error("empty source", function()
  native.render("", { width = 80 })
end, "empty mermaid source")

expect_error("malformed source", function()
  native.render("flowchart TD\n  A -->", { width = 80 })
end, "mermaid parse error")

expect_error("unsupported type", function()
  native.render('pie title Pets\n  "Dogs" : 386', { width = 80 })
end, "unsupported diagram")

expect_error("size guard", function()
  local src = { "flowchart TD" }
  for i = 1, 300 do
    src[#src + 1] = ("  N%d --> N%d"):format(i, i + 1)
  end
  native.render(table.concat(src, "\n"), { width = 80 })
end, "too large")

expect_error("custom max_src_lines", function()
  native.render("flowchart TD\n  A --> B\n  B --> C", { max_src_lines = 2 })
end, "too large")

expect_error("invalid charset", function()
  native.render("flowchart TD\n  A --> B", { charset = "klingon" })
end, "charset")

expect_error("invalid width", function()
  native.render("flowchart TD\n  A --> B", { width = 0 })
end, "width")

expect_error("width of the wrong type", function()
  native.render("flowchart TD\n  A --> B", { width = {} })
end, "opts.width")

expect_error("source of the wrong type", function()
  native.render(nil, {})
end, "src must be a string")

expect_error("missing arguments", function()
  native.render()
end, "src must be a string")

expect_error("opts of the wrong type", function()
  native.render("flowchart TD\n  A --> B", 5)
end, "opts must be a table")

expect_error("unknown diagram_ty", function()
  native.render("flowchart TD\n  A --> B", { diagram_ty = "nope" })
end, "nope")

-- 4. O modulo continua utilizavel depois de varios erros.
local after = native.render("flowchart TD\n  X --> Y", { width = 80 })
check("render still works after errors", type(after) == "table" and #after > 3)

-- 5. Bytes invalidos em UTF-8 (buffer do Neovim pode ter) viram U+FFFD, nao erro nem crash.
local ok_bytes, bytes_out =
  pcall(native.render, "flowchart TD\n  A[\255\254] --> B", { width = 80 })
check("invalid utf-8 is replaced, not rejected", ok_bytes and #bytes_out > 3, bytes_out)

-- 6. Contrato do erro que a fase 7 recebe de `pcall`: a mensagem exata, sem decoracao.
local _, err_value = pcall(native.render, "", { width = 80 })
check("error value is exactly the message", err_value == "empty mermaid source", err_value)

if #failures > 0 then
  print(("\n%d check(s) failed: %s"):format(#failures, table.concat(failures, ", ")))
  os.exit(1)
end

-- Chegar aqui, com o processo vivo e exit 0, e a prova: nenhum dos erros acima abortou o nvim.
print("\nnative: processo sobreviveu a todos os erros\n")
os.exit(0)
