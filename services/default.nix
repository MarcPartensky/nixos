{
  pkgs,
  config,
  ...
}: {
  imports = [
    # ./zitadel
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
    ./rqbit
    ./autossh
    ./wayvnc
    # ./dnscrypt
    ./adguard
    ./navidrome
    ./tor
    ./minio
    # ./syncserver
    # ./newt # attendre maj flakes
  ];
}
