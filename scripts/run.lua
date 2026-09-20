-- Driver do mini.test.
--
-- Existe por causa do gate 1 da fase 0: a suíte precisa sair com exit code diferente de
-- zero em TODA forma de falha, não só em asserção quebrada. O `MiniTest.run()` sozinho
-- resolve o caso do teste que falha (ele chama `1cquit`), mas não resolve:
--
--   * erro de sintaxe num arquivo de teste, que estoura durante a coleta;
--   * glob que não casa com nada, que "passa" com zero casos;
--   * erro dentro de um hook, que aborta antes do relatório.
--
-- Nos três casos o `-c "qa!"` do shell script sairia com 0 e a suíte inteira viraria
-- teatro. Este arquivo fecha isso.

---@param msg string
local function die(msg)
  io.stderr:write("\n[runner] " .. msg .. "\n")
  vim.cmd("silent! 1cquit")
end

local target = vim.env.DECKLE_TEST_FILE

local ok, err = pcall(function()
  if target and target ~= "" then
    MiniTest.run_file(target)
  else
    MiniTest.run()
  end
end)

-- Se algum caso falhou, o mini.test já chamou `1cquit` e não chegamos aqui.
if not ok then
  die("a suite nao chegou ao fim: " .. tostring(err))
end

-- Suite que nao coletou nada nao e sucesso: e glob quebrado ou diretorio errado.
local cases = MiniTest.current.all_cases or {}
if #cases == 0 then
  die("nenhum caso de teste foi coletado" .. (target and (" em " .. target) or ""))
end
