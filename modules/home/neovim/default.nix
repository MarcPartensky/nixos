{pkgs, ...}: {
  imports = [
    ./plugins/cmp.nix
    ./plugins/lsp.nix
    ./plugins/conform.nix
    ./plugins/ui.nix
    ./plugins/avante.nix
  ];

  home.packages = with pkgs; [
  ];

  programs.nixvim = {
    enable = true;
    # # colorschemes.catppuccin.enable = true;
    opts = import ./options.nix;
    keymaps = import ./keymaps.nix;

    filetype = {
      extension = {
        yuck = "yuck";
      };
    };

    plugins = {
      avante = {
        enable = true;
        settings = {
          provider = "claude";
          # On déplace tout dans providers.claude
          providers = {
            claude = {
              endpoint = "https://api.anthropic.com";
              model = "claude-3-5-sonnet-20241022";
              # Température et tokens vont maintenant dans extra_request_body
              extra_request_body = {
                temperature = 0;
                max_tokens = 4096;
              };
            };
          };
          behaviour = {
            auto_suggestions = false;
            support_paste_from_clipboard = true;
          };
          window = {
            position = "right";
            width = 30;
          };
        };
      };

      lualine = {
        enable = true;
        settings = {
          colorscheme = "wombat";
        };
      };
      treesitter = {
        enable = true;
        # Assure-toi que le parser yuck est bien chargé
        nixGrammars = true; # Utilise les paquets Nix pour les grammaires
        settings = {
          ensure_installed = ["yuck" "nix" "lua" "bash" "markdown"]; # Ajoute "yuck" ici
          highlight.enable = true;
        };
      };
    };

    plugins.neo-tree = {
      enable = true;
      settings = import ./plugins/neo-tree.nix;
    };
    plugins.auto-session = {
      enable = true;
      settings = import ./plugins/auto-session.nix;
    };

    colorschemes.onedark.enable = true;
    extraConfigLua = builtins.readFile ./extra_config.lua;

    extraPlugins = with pkgs.vimPlugins; [
      auto-session
      vim-toml
      lualine-nvim
      onedark-nvim
      bufferline-nvim
      telescope-nvim
      nvim-cmp
      nvim-lspconfig
      nvim-web-devicons
      # vim-autopairs
      dashboard-nvim
      lspsaga-nvim
      scrollbar-nvim
      neo-tree-nvim
      vim-smoothie
      comment-nvim
      treesj
      # session-manager-nvim
      dressing-nvim
      # markdown-preview-nvim
      avante-nvim
      # telescope-recent-files-nvim
      toggleterm-nvim
      vim-nix
    ];
  };
}
