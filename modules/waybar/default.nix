{ inputs, pkgs, ... }: {

  # imports = [
  #   # ./plugins.nix

  # ];


  home-manager.users.marc = { pkgs, inputs, ... }: {
    # programs.waybar = {
    #   enable = true;
    #   package = inputs.hyprland.packages.${pkgs.system}.waybar-hyprland
    # };
    programs.waybar.package = pkgs.waybar.overrideAttrs (oa: {
      mesonFlags = (oa.mesonFlags or  []) ++ [ "-Dexperimental=true" ];
      patches = (oa.patches or []) ++ [
        (pkgs.fetchpatch {
          name = "fix waybar hyprctl";
          url = "https://aur.archlinux.org/cgit/aur.git/plain/hyprctl.patch?h=waybar-hyprland-git";
          sha256 = "sha256-pY3+9Dhi61Jo2cPnBdmn3NUTSA8bAbtgsk2ooj4y7aQ=";
        })
      ];
    });

  };
}
