{
  pkgs,
  config,
  ...
}: {
  imports = [
    ./nextcloud
    ./postgres
    ./vaultwarden
    ./newt
    ./readarr
    ./radarr
    ./sonarr
    ./prowlarr
    ./flaresolverr
    ./qbittorrent
    # ./dnscrypt
    ./adguard
    ./navidrome
    ./tor
    # ./syncserver
    # ./newt # attendre maj flakes
  ];
}
