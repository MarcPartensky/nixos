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
    # The sources.video key corresponds to the <video> section in sources.xml
    sources.video = [
      {
        name = "movies";
        path = "/srv/media/movies/";
        # 'allowsharing = true;' shares over upnp
      }
      {
        name = "tvshows";
        path = "/srv/media/tvshows/";
      }
    ];
  };
}
