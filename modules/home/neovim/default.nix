{pkgs, ...}: {
  imports = [
    ./plugins/cmp.nix
    ./plugins/lsp.nix
    ./plugins/conform.nix
    ./plugins/ui.nix
  ];

  # home.packages = with pkgs; [ ansible-language-server ];
  programs.nixvim = {
    enable = true;
    # # colorschemes.catppuccin.enable = true;
    opts = import ./options.nix;
    keymaps = import ./keymaps.nix;

    plugins = {
      avante.enable = true;

      lualine = {
        enable = true;
        settings = {
          colorscheme = "wombat";
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
