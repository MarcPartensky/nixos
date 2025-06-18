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
  programs.hyprland = {
    enable = true;
    # set the flake package
    package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    # make sure to also set the portal package, so that they are in sync
    portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
  };
}
