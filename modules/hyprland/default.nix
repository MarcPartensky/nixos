# { inputs, pkgs, lib, config, ... }:

# with lib;
# let cfg = config.modules.hyprland;

# in {
#     options.modules.hyprland= { enable = mkEnableOption "hyprland"; };
#     config = mkIf cfg.enable {
# 	home.packages = with pkgs; [
# 	    wofi swaybg wlsunset wl-clipboard hyprland
# 	];

#         home.file.".config/hypr/hyprland.conf".source = ./hyprland.conf;
#     };
# }

{inputs, pkgs, ...}: {
  # home.file.".config/hypr/hyprland.conf".source = ./hyprland.conf;

  imports = [
    # ./plugins.nix

  ];

  nix.settings = {
    substituters = ["https://hyprland.cachix.org"];
    trusted-substituters = ["https://hyprland.cachix.org"];
    trusted-public-keys = ["hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="];
  };

  programs.hyprland = {
    enable = true;
    # set the flake package
    package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    # make sure to also set the portal package, so that they are in sync
    portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
  };
}
