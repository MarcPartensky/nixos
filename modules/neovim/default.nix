{ pkgs, ... }:
{
  programs.nixvim = {
    enable = true;
    # colorschemes.catppuccin.enable = true;
    colorschemes.onedark.enable = true;
    opts = {
      number = true;         # Show line numbers
      relativenumber = true; # Show relative line numbers
      shiftwidth = 2;        # Tab width should be 2
      tabstop = 2;
      expandtab = false;
    };
    plugins.lualine = {
      enable = true;
      settings = {
        colorscheme = "wombat";
      };
    };
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
      markdown-preview-nvim
      avante-nvim
      # telescope-recent-files-nvim
      toggleterm-nvim
      vim-nix
    ];
  };
}
