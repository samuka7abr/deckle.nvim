--- Grupos de highlight do deckle.
---
--- Todos com `default = true` e linkados a grupos padrão do Neovim (ou, quando não existe
--- grupo padrão para o efeito, com o atributo mínimo): o esquema de cores do usuário, ou um
--- `nvim_set_hl` dele feito antes, sempre vence. Para trocar a aparência, sobrescreva o grupo:
---
--- ```lua
--- vim.api.nvim_set_hl(0, "DeckleH1", { fg = "#ff9e64", bold = true })
--- ```
---
--- Para um tipo de bloco novo, acrescente o grupo em `M.groups` e use o nome em `hl` nas
--- marcas do módulo de render (ver `deckle.render`).

local M = {}

---@type table<string, vim.api.keyset.highlight>
M.groups = {
  -- Títulos. Todos no mesmo grupo de fábrica; o nível aparece também no sublinhado do H1/H2.
  DeckleH1 = { link = "Title" },
  DeckleH2 = { link = "Title" },
  DeckleH3 = { link = "Title" },
  DeckleH4 = { link = "Title" },
  DeckleH5 = { link = "Title" },
  DeckleH6 = { link = "Title" },

  -- Texto inline.
  DeckleStrong = { bold = true },
  DeckleEmphasis = { italic = true },
  DeckleCodeInline = { link = "String" },
  DeckleLink = { link = "Underlined" },
  DeckleImage = { link = "Special" },

  -- Blocos.
  DeckleCode = { link = "ColorColumn" },
  DeckleQuote = { link = "Comment" },
  DeckleBullet = { link = "Special" },
  DeckleRule = { link = "Comment" },
  DeckleHtml = { link = "Comment" },
  DeckleTableHeader = { link = "Title" },
  DeckleTableBorder = { link = "Comment" },

  -- Bloco que o render não conseguiu desenhar.
  DeckleError = { link = "WarningMsg" },
}

local augroup = "DeckleHighlights"

local function apply()
  for name, definition in pairs(M.groups) do
    local spec = vim.tbl_extend("force", { default = true }, definition)
    vim.api.nvim_set_hl(0, name, spec)
  end
end

--- Define os grupos e os redefine a cada `:colorscheme` (que limpa os grupos criados por
--- `nvim_set_hl`). Idempotente: chamar de novo não duplica o autocmd.
function M.setup()
  apply()
  vim.api.nvim_create_augroup(augroup, { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    desc = "deckle: redefine highlight groups after a colorscheme change",
    callback = apply,
  })
end

return M
