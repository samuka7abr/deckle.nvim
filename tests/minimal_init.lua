-- Init mínimo usado pelos testes (mini.test), via `nvim --headless -u tests/minimal_init.lua`.
-- Não carrega o plugin nem chama setup do deckle: cada teste faz isso explicitamente.

-- Raiz do repo = diretório pai de tests/, resolvido a partir do path deste próprio arquivo
-- (não depende do cwd de onde o nvim foi chamado).
local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local repo_root = vim.fn.fnamemodify(this_file, ":p:h:h")

vim.opt.rtp:prepend(repo_root .. "/.deps/mini.nvim")
vim.opt.rtp:prepend(repo_root)

require("mini.test").setup()
