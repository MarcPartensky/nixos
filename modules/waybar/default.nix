{ inputs, pkgs, ... }: {

  # imports = [
  #   # ./plugins.nix

  # ];


  home-manager.users.marc = { pkgs, inputs, ... }: {
    programs.waybar = {
      enable = true;
      package = inputs.hyprland.packages.${pkgs.system}.waybar-hyprland
    };
  };
}
