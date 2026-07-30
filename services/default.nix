{
  pkgs,
  config,
  ...
}: {
  imports = [
    # ./nextcloud
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
    # ./minio
    ./jupyterhub
    # ./gotify
    # ./zitadel
    # ./syncserver
    # ./newt # attendre maj flakes
  ];
}
