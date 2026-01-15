{pkgs, ...}: {
  programs.nixvim = {
    colorschemes.onedark.enable = true;

    plugins = {
      lualine = {
        enable = true;
        settings.options.theme = "wombat";
      };

      neo-tree = {
        enable = true;
        settings.enable_git_status = true;
        # Si tu as un fichier de settings séparé :
        # settings = import ./neo-tree-settings.nix;
      };
    };
  };
}
