--- Registra `:Deckle` e sai.
---
--- Nada de `require("deckle")` aqui: o custo do plugin no startup precisa ser só a criação
--- do comando. O módulo só carrega quando o comando roda ou quando o usuário chama
--- `setup()`.

if vim.g.loaded_deckle == 1 then
  return
end
vim.g.loaded_deckle = 1

if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("deckle.nvim requires Neovim 0.11.0 or newer", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Deckle", function(cmd)
  require("deckle").dispatch(cmd.fargs)
end, {
  nargs = "*",
  desc = "deckle: markdown preview in a separate buffer",
  complete = function(arglead, cmdline, cursorpos)
    return require("deckle").complete(arglead, cmdline, cursorpos)
  end,
})
