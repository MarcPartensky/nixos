-- =======================================================
-- ADDITIONAL LUA CONFIGURATION (Transparency and Autocmd)
-- =======================================================

-- 1. BACKGROUND TRANSPARENCY
-- onedark is configured with transparent = true (plugins/ui.nix), which removes
-- already the background of Normal/EndOfBuffer/SignColumn/NeoTree. We still force
-- the remaining groups, and especially ALL Lualine groups: the status
-- bar is an opaque gray strip as long as its sections keep a bg.
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

-- With a transparent background, the end-of-buffer ~ (fg = bg0 in onedark)
-- would become visible over the wallpaper: we replace them with spaces.
vim.opt.fillchars:append({ eob = " " })

vim.api.nvim_create_autocmd({ "VimEnter", "ColorScheme" }, {
  group = vim.api.nvim_create_augroup("TransparentUI", { clear = true }),
  callback = function()
    -- deferred: Lualine (re)sets its highlights on load and on ColorScheme
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

-- 2. AUTOCOMMANDS FOR MARKDOWN/TXT (Wrapping)
-- Create a group to organize the autocommands
local markdown_settings_group = vim.api.nvim_create_augroup("MarkdownSettings", { clear = true })

-- Callback function to set local wrap options
local function set_wrap_options()
    vim.opt_local.textwidth = 80
    vim.opt_local.wrapmargin = 2
    vim.opt_local.wrap = true -- Enable wrap locally
end

-- Apply the options when .md and .txt files are loaded
vim.api.nvim_create_autocmd("FileType", {
  group = markdown_settings_group,
  pattern = { "markdown", "txt" },
  callback = set_wrap_options,
})

-- 3. AUTOCOMMANDS FOR AVANTE/CHATGPT
vim.api.nvim_create_autocmd("User", {
  pattern = "ToggleMyPrompt",
  callback = function()
    require("avante.config").override({ system_prompt = "MY CUSTOM SYSTEM PROMPT" })
  end,
})

-- 4. OTHER LUA CONFIGURATIONS IF NEEDED (e.g., set up plugins that require Lua)
-- (You could add Avante's configuration here if the plugin requires it)
-- Example: require('avante').setup({})
