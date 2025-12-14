-- =======================================================
-- CONFIGURATION LUA SUPPLÉMENTAIRE (Transparence et Autocmd)
-- =======================================================

-- 1. TRANSPARENCE DU FOND
-- Rendre le fond du thème transparent en supprimant la couleur de fond (guibg=NONE)
vim.cmd("highlight Normal guibg=NONE")
vim.cmd("highlight NormalFloat guibg=NONE")
vim.cmd("highlight FloatBorder guibg=NONE")

-- Rendre la ligne de statut (Lualine) transparente si elle l'était par défaut
vim.cmd("highlight Lualine_a_normal guibg=NONE")
vim.cmd("highlight Lualine_b_normal guibg=NONE")
vim.cmd("highlight Lualine_c_normal guibg=NONE")

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
