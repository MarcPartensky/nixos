{pkgs, ...}: {
  programs.nixvim = {
    # transparent = true removes the opaque background from ALL theme groups
    # (Normal, EndOfBuffer, SignColumn, NeoTreeNormal...), not just Normal.
    # Without it, the empty area below the end of the buffer keeps onedark's gray bg0.
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
        # If you have a separate settings file:
        # settings = import ./neo-tree-settings.nix;
      };
    };
  };
}
