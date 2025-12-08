{ pkgs, ... }:

let
  # ⚙️ Configuration Lazy
  lazy-nvim-config = {
    # La configuration de Lazy se fait ici
    -- Exemple: checker = { enabled = true }
    checker.enable = true;
    # Pas besoin de la liste `spec` car Nix-Vim la gère déjà
    # en utilisant les plugins déclarés ci-dessous.
  };

  # 🚀 Plugins déclarés
  # On utilise le format 'nom-du-repo' : { optionals, ... }
  myPlugins = {
    # Thèmes
    "folke/tokyonight.nvim" = {
      # theme, mais vous aviez mis onedark
      # onedark.nvim est géré plus bas
    };
    "navarasu/onedark.nvim" = {
      enable = true;
      # Configurez le thème ici si besoin
      # exemple: colorscheme.style = "deep";
    };
    # "sainnhe/everforest" = { }; # Exemple si vous vouliez wal
    # Syntax, Buffers, Search
    "nvim-treesitter/nvim-treesitter" = {
      # enable = true; # Souvent déjà activé par défaut
    };
    "akinsho/bufferline.nvim" = {}; # tabs
    "nvim-telescope/telescope.nvim" = {}; # search
    "nvim-tree/nvim-web-devicons" = {}; # icons
    "stevearc/conform.nvim" = {}; # autoformatter
    "nvim-lualine/lualine.nvim" = {}; # bottom bar
    "windf/nvim-autopairs" = {
      config = "require('nvim-autopairs').setup({})";
    }; # autopairs
    "goolord/alpha-nvim" = {
      # dashboard, souvent appelé alpha-nvim
      # Le setup est généralement fait dans un fichier séparé
    };
    "lspsaga/lspsaga.nvim" = {}; # lsp show function params
    "petertriho/nvim-scrollbar" = {}; # scrollbar
    "nvim-neo-tree/neo-tree.nvim" = {}; # tab for file explorer
    "b0o/schemastore.nvim" = {
      # Souvent utile avec lspconfig
    };
    "karb94/neoscroll.nvim" = {
      # Alternative à vim-smoothie
      config = ''
        require('neoscroll').setup({
          mappings = { '<C-u>', '<C-d>', '<C-b>', '<C-f>', 'zt', 'zz', 'zb' },
          easing = 'sine',
          hide_cursor = true,
          # ... autres options
        })
      '';
    };
    "numToStr/Comment.nvim" = {}; # comment
    "Wansmer/treesj" = {}; # split/join blocks of code
    "folke/noice.nvim" = {
      # notifications - vous l'aviez mis en commentaire
      # enable = true;
    };
    "folke/persistence.nvim" = {
      # session-manager - persistence.nvim est l'alternative lazy
      config = "require('persistence').setup({})";
    };
    "stevearc/dressing.nvim" = {}; # nice ui for selection
    "zbirenbaum/copilot.lua" = {
      # Alternative à 'gp' ou 'chatgpt' si vous utilisez Copilot
      # Vous devriez adapter cela à 'gp' ou 'chatgpt' si vous les préférez
    };
    "ellisonleao/gruvbox.nvim" = {
      # Avante n'est pas un plugin standard. J'utilise un autre exemple
      # Si 'avante' est un plugin spécifique, vous devez le trouver sur GitHub
      # "Avante/avante" = { };
    };
    "nvim-telescope/telescope-frecency.nvim" = {
      # telescope-recent-files utilise souvent frecency
    };
    "akinsho/toggleterm.nvim" = {
      config = "require('toggleterm').setup({})";
    }; # toggleterm
    "williamboman/mason-lspconfig.nvim" = {};
    "williamboman/mason.nvim" = {}; # Requis par Mason-lspconfig
    "nvim-treesitter/nvim-treesitter-textobjects" = {}; # Utile pour treesitter
    "hrsh7th/nvim-cmp" = {}; # autocompletion
    "neovim/nvim-lspconfig" = {}; # language autocompletion

    # Markdown Preview nécessite une gestion spéciale
    # Nous le traitons séparément avec `extraPlugins`
  };
in
{
  # Active le support de Nix-Vim
  programs.nix-vim = {
    enable = true;

    # 1. Configuration Lazy
    plugins.lazy.config = lazy-nvim-config;

    # 2. Déclaration des plugins
    plugins = myPlugins // {
      # Déclare l'utilisation de Lazy pour gérer le tout
      lazy.enable = true;
    };

    # 3. Traitement spécial pour markdown-preview
    # Comme il a une étape de `run`, nous utilisons `extraPlugins`
    # et le paquet `vimPlugins` de Nixpkgs.

    extraPlugins = with pkgs.vimPlugins; [
      # Il faut trouver le paquet nix correspondant.
      # Le paquet standard est `markdown-preview-nvim`.
      (markdown-preview-nvim.overrideAttrs (old: {
        # L'étape `run = "cd app && yarn install"` est gérée par Nix.
        # Vous devriez vous assurer que le paquet Nix est bien construit,
        # ou utiliser une méthode de packaging plus avancée (flake, etc.).
        # Pour home-manager simple, on s'appuie sur le paquet nix existant.
      }))
    ];

    # 4. Activation des plugins de base (si non déjà dans `myPlugins`)
    # Pour s'assurer que l'environnement est complet
    # plugins.treesitter.enable = true;
    # plugins.lsp.enable = true;
    # plugins.cmp.enable = true;
  };

  # Si vous souhaitez une configuration des raccourcis claviers, des options, etc.
  # programmes.nix-vim.config = {
  #   # Options globales
  #   opts = {
  #     relativenumber = true;
  #     shiftwidth = 2;
  #   };
  #   # Raccourcis
  #   keymaps = [
  #     { mode = "n"; key = "<leader>ff"; action = "<cmd>Telescope find_files<cr>"; options = { desc = "Find files"; }; }
  #   ];
  # };
}
