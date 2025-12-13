{ pkgs, ... }: {
  home-manager.users.marc = { pkgs, ... }: {
    home.packages = [
      (pkgs.kodi-wayland.withPackages (kodiPkgs: with kodiPkgs; [
        jellyfin
        jellycon
        netflix
        youtube
      ]))
    ];
  };
}
