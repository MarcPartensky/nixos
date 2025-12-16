{ pkgs, ... }:
let
  homeDir = "/home/marc";
in {
  programs.kodi = {
    enable = true;
    package = pkgs.kodi-wayland.withPackages (kodiPkgs: with kodiPkgs; [
      jellyfin
      jellycon
      netflix
      youtube
    ]);
    # settings = {
    # };
    # La clé sources.video correspond à la section <video> dans sources.xml
    sources.video = [
      {
        name = "movies";
        path = "${homeDir}/media/movies/";
        # 'allowsharing = true;' partage upnp
      }
      {
        name = "tvshows";
        path = "${homeDir}/media/tvshows/";
      }
    ];
  };
}
