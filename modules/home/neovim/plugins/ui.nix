{pkgs, ...}: {
  programs.nixvim = {
    # transparent = true retire le fond opaque de TOUS les groupes du thème
    # (Normal, EndOfBuffer, SignColumn, NeoTreeNormal...), pas seulement Normal.
    # Sans ça, la zone vide sous la fin du buffer garde le bg0 gris de onedark.
    colorschemes.onedark = {
      enable = true;
      settings.transparent = true;
    };

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
