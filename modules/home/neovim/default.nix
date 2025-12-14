{ pkgs, ... }:
{
  # home.packages = with pkgs; [ ansible-language-server ];
  programs.nixvim = {
    enable = true;
    # # colorschemes.catppuccin.enable = true;
    opts = import ./options.nix;
    keymaps = import ./keymaps.nix;

    plugins.lualine = {
      enable = true;
      settings = {
        colorscheme = "wombat";
      };
    };

    colorschemes.onedark.enable = true;
    extraConfigLua = builtins.readFile ./extra_config.lua;

    extraPlugins = with pkgs.vimPlugins; [
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
