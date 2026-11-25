{
  pkgs,
  inputs,
  ...
}: {
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
    # Build nixvim on the system nixpkgs (instead of nixvim's internal
    # nixpkgs input): a single nixpkgs eval and it permanently
    # removes the warning "nixpkgs.source affected by your flake follows"
    # (which compares the rev to the one tested by nixvim's CI).
    nixpkgs.source = inputs.nixpkgs;
    # # colorschemes.catppuccin.enable = true;
    opts = import ./options.nix;
    keymaps = import ./keymaps.nix;
    clipboard.register = "unnamedplus"; # yank => direct clipboard

    filetype = {
      extension = {
        yuck = "yuck";
      };
    };

    plugins = {
      web-devicons.enable = true;
      lsp.servers.nil_ls = {
        enable = true;
        settings."nil".nix.flake = {
          autoArchive = false; # or true to fetch silently
          # autoEvalInputs = false;
        };
      };
      avante = {
        enable = true;
        settings = {
          provider = "claude";
          # We move everything into providers.claude
          providers = {
            claude = {
              endpoint = "https://api.anthropic.com";
              model = "claude-3-5-sonnet-20241022";
              # Temperature and tokens now go into extra_request_body
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
      lspsaga = {
        enable = true;
        settings = {
          ui.border = "rounded";
          lightbulb.enable = false; # avoids spam if no LSP is active
        };
      };
      treesitter = {
        enable = true;
        # Make sure the yuck parser is properly loaded
        nixGrammars = true; # Uses the Nix packages for the grammars
        settings = {
          ensure_installed = ["yuck" "nix" "lua" "bash" "markdown"]; # Add "yuck" here
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
