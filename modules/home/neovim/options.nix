{
  # inspiré de https://github.com/brainfucksec/neovim-lua/blob/main/nvim/lua/core/options.lua

  # GENERAL
  swapfile = false;
  clipboard = "unnamedplus";
  undofile = true;
  completeopt = "menuone,noinsert,noselect";
  textwidth = 80;
  # Pour ajouter 't' à formatoptions, il faut utiliser la fonction concat
  # (sera géré dans l'import pour simplifier)

  # NEVIM UI
  # Note : Vous avez 'number = false' et 'nu = true' (équivalent à number=true)
  # J'utilise 'nu = true' pour correspondre à votre dernière définition
  number = true;
  relativenumber = true;
  smartcase = true;
  linebreak = true;
  ignorecase = true;
  guicursor = "";
  # laststatus = 3; # Non inclus dans la plupart des opts standard de nixvim
  background = "dark";
  hlsearch = false;
  incsearch = true;
  wrap = false; # Désactiver le wrapping général
  termguicolors = true; # Permet à Neovim d'utiliser les vraies couleurs
  winblend = 0;         # Transparence pour les fenêtres flottantes (0 = opaque, 100 = transparent)
  
  # TABS / INDENTS
  expandtab = true;
  smartindent = true;
  tabstop = 4;
  softtabstop = 4;
  shiftwidth = 4;

}
