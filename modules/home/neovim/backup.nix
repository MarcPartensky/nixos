{ pkgs, ... }:
# let
#   # ⚙️ Configuration Lazy
#   lazy-nvim-config = {
#     # Active la vérification automatique des mises à jour des plugins
#     checker.enable = true;
#   };
#
#   # 🚀 Liste déclarative de TOUS les plugins
#   myPlugins = {
#     # Thèmes
#     "folke/tokyonight.nvim" = {};
#     "navarasu/onedark.nvim" = {
#       enable = true;
#       # colorscheme.style = "deep";
#     };
#
#     # Core & UI
#     "nvim-treesitter/nvim-treesitter" = {};
#     "akinsho/bufferline.nvim" = {}; # tabs
#     "nvim-tree/nvim-web-devicons" = {}; # icons
#     "nvim-lualine/lualine.nvim" = {}; # bottom bar
#     "windf/nvim-autopairs" = {
#       config = "require('nvim-autopairs').setup({})";
#     };
#     "goolord/alpha-nvim" = {}; # dashboard
#     "petertriho/nvim-scrollbar" = {}; # scrollbar
#     "nvim-neo-tree/neo-tree.nvim" = {}; # file explorer
#     "karb94/neoscroll.nvim" = { # smooth scroll (remplace vim-smoothie)
#       config = ''
#         require('neoscroll').setup({
#           mappings = { '<C-u>', '<C-d>', '<C-b>', '<C-f>', 'zt', 'zz', 'zb' },
#           easing = 'sine',
#           hide_cursor = true,
#         })
#       '';
#     };
#     "numToStr/Comment.nvim" = {}; # comment
#     "Wansmer/treesj" = {}; # split/join blocks of code
#     "folke/persistence.nvim" = { # session-manager
#       config = "require('persistence').setup({})";
#     };
#     "stevearc/dressing.nvim" = {}; # nice ui for selection
#     "akinsho/toggleterm.nvim" = {
#       config = "require('toggleterm').setup({})";
#     };
#
#     # LSP & Complétion
#     "williamboman/mason.nvim" = {}; # Requis par Mason-lspconfig
#     "williamboman/mason-lspconfig.nvim" = {};
#     "neovim/nvim-lspconfig" = {}; # language autocompletion
#     "hrsh7th/nvim-cmp" = {}; # autocompletion
#     "lspsaga/lspsaga.nvim" = {}; # lsp show function params
#     "b0o/schemastore.nvim" = {}; # Utile avec LSP pour les schémas JSON
#     "stevearc/conform.nvim" = {}; # autoformatter
#     "nvim-treesitter/nvim-treesitter-textobjects" = {}; # Utile pour treesitter
#
#     # Recherche
#     "nvim-telescope/telescope.nvim" = {}; # search
#     "nvim-telescope/telescope-frecency.nvim" = {}; # recent files (remplace telescope-recent-files)
#
#     # IA (Gardé l'alternative Copilot comme marqueur)
#     "zbirenbaum/copilot.lua" = {}; # Alternative à 'gp'
#
#     # Thème générique (remplace avante)
#     "ellisonleao/gruvbox.nvim" = {}; 
#
#     # Notifications (optionnel, était commenté)
#     # "folke/noice.nvim" = {};
#   };
# in
{
  programs.nixvim = {
    enable = true;
    colorschemes.catppuccin.enable = true;
    plugins.lualine.enable = true;

    # Correction de l'erreur : Toutes les configurations de plugins sont fusionnées ici
  #   plugins = myPlugins // {
  #     # Active et configure Lazy
  #     lazy = {
  #       enable = true;
  #       config = lazy-nvim-config;
  #     };
  #   };
  #
  #   # Traitement spécial pour markdown-preview
  #   # Ceci est nécessaire car le plugin nécessite un step `run` non standard.
  #   extraPlugins = with pkgs.vimPlugins; [
  #     (markdown-preview-nvim.overrideAttrs (old: {
  #       # Note : On s'appuie sur le packaging Nixpkgs qui inclut les dépendances Node/Yarn.
  #     }))
  #   ];
  #
  #   # Configuration Neovim (Options et Keymaps)
  #   config = {
  #     # Options globales
  #     opts = {
  #       mapleader = " "; # Définition de l'espace comme leader
  #       maplocalleader = "\\";
  #       relativenumber = true;
  #       shiftwidth = 2;
  #       tabstop = 2;
  #       expandtab = true;
  #       # ... autres opts ...
  #     };
  #
  #     # Raccourcis claviers (Keymaps) - Exemple :
  #     # keymaps = [
  #     #   { mode = "n"; key = "<leader>ff"; action = "<cmd>Telescope find_files<cr>"; options = { desc = "Find files"; }; }
  #     # ];
  #
  #     # Configuration de couleur (Active onedark au démarrage)
  #     colorschemes.onedark.enable = true;
  #   };
  };
}
