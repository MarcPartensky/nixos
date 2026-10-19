-- =======================================================
-- CONFIGURATION LUA SUPPLÉMENTAIRE (Transparence et Autocmd)
-- =======================================================

-- 1. TRANSPARENCE DU FOND
-- onedark est configuré avec transparent = true (plugins/ui.nix), ce qui enlève
-- déjà le fond de Normal/EndOfBuffer/SignColumn/NeoTree. On force quand même
-- les groupes restants, et surtout TOUS les groupes Lualine : la barre de
-- statut est une bande grise opaque tant que ses sections gardent un bg.
local transparent_groups = {
  "Normal",
  "NormalFloat",
  "FloatBorder",
  "EndOfBuffer",
  "StatusLine",
  "StatusLineNC",
}

local function set_transparent_hl()
  for _, name in ipairs(transparent_groups) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
    if ok then
      hl.bg = nil
      hl.ctermbg = nil
      vim.api.nvim_set_hl(0, name, hl)
    end
  end

  for _, name in ipairs(vim.fn.getcompletion("Lualine", "highlight")) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
    if ok then
      hl.bg = nil
      hl.ctermbg = nil
      vim.api.nvim_set_hl(0, name, hl)
    end
  end
end

-- Avec un fond transparent, les ~ de fin de buffer (fg = bg0 chez onedark)
-- deviendraient visibles sur le papier peint : on les remplace par des espaces.
vim.opt.fillchars:append({ eob = " " })

vim.api.nvim_create_autocmd({ "VimEnter", "ColorScheme" }, {
  group = vim.api.nvim_create_augroup("TransparentUI", { clear = true }),
  callback = function()
    -- différé : Lualine (re)pose ses highlights au chargement et au ColorScheme
    vim.schedule(set_transparent_hl)
  end,
})



vim.g.clipboard = {
      name = 'OSC 52',
      copy = {
        ['+'] = require('vim.ui.clipboard.osc52').copy('+'),
        ['*'] = require('vim.ui.clipboard.osc52').copy('*'),
      },
      paste = {
        ['+'] = require('vim.ui.clipboard.osc52').paste('+'),
        ['*'] = require('vim.ui.clipboard.osc52').paste('*'),
      },
    }

-- 2. AUTOCOMMANDS POUR MARKDOWN/TXT (Wrapping)
-- Crée un groupe pour organiser les autocommands
local markdown_settings_group = vim.api.nvim_create_augroup("MarkdownSettings", { clear = true })

-- Fonction de rappel pour définir les options locales de wrap
local function set_wrap_options()
    vim.opt_local.textwidth = 80
    vim.opt_local.wrapmargin = 2
    vim.opt_local.wrap = true -- Activation du wrap localement
end

-- Appliquer les options au chargement des fichiers .md et .txt
vim.api.nvim_create_autocmd("FileType", {
  group = markdown_settings_group,
  pattern = { "markdown", "txt" },
  callback = set_wrap_options,
})

-- 3. AUTOCOMMANDS POUR AVANTE/CHATGPT
vim.api.nvim_create_autocmd("User", {
  pattern = "ToggleMyPrompt",
  callback = function()
    require("avante.config").override({ system_prompt = "MY CUSTOM SYSTEM PROMPT" })
  end,
})

-- 4. AUTRES CONFIGURATIONS LUA SI NÉCESSAIRE (e.g., set up plugins that require Lua)
-- (Vous pourriez y ajouter ici la configuration d'Avante si le plugin le requiert)
-- Exemple: require('avante').setup({})
