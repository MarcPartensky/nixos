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
  # programs.hyprland = {
  #   enable = true;
  #   # set the flake package
  #   package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
  #   # make sure to also set the portal package, so that they are in sync
  #   portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
  # };
  # home.file.".config/hypr/hyprland.conf".source = ./hyprland.conf;


  wayland.windowManager.hyprland.settings = {
    "$mod" = "SUPER";
    bind =
      [
        "$mod, D, exec, wofi --show drun"
        ", Print, exec, grimblast copy area"
      ]
      ++ (
        # workspaces
        # binds $mod + [shift +] {1..9} to [move to] workspace {1..9}
        builtins.concatLists (builtins.genList (i:
            let ws = i + 1;
            in [
              "$mod, code:1${toString i}, workspace, ${toString ws}"
              "ALT, code:1${toString i}, movetoworkspace, ${toString ws}"
            ]
          )
          9)
      );
  };
}
