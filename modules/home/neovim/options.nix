{
  # inspired by https://github.com/brainfucksec/neovim-lua/blob/main/nvim/lua/core/options.lua

  # GENERAL
  swapfile = false;
  clipboard = "unnamedplus";
  undofile = true;
  completeopt = "menuone,noinsert,noselect";
  textwidth = 80;
  # To add 't' to formatoptions, one must use the concat function
  # (will be handled in the import to simplify)

  # NEVIM UI
  # Note: You have 'number = false' and 'nu = true' (equivalent to number=true)
  # I use 'nu = true' to match your last definition
  number = true;
  relativenumber = true;
  smartcase = true;
  linebreak = true;
  ignorecase = true;
  guicursor = "";
  # laststatus = 3; # Not included in most of nixvim's standard opts
  background = "dark";
  hlsearch = false;
  incsearch = true;
  wrap = false; # Disable general wrapping
  termguicolors = true; # Allows Neovim to use true colors
  winblend = 0;         # Transparency for floating windows (0 = opaque, 100 = transparent)
  
  # TABS / INDENTS
  expandtab = true;
  smartindent = true;
  tabstop = 4;
  softtabstop = 4;
  shiftwidth = 4;

}
