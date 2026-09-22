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
    # ./radarr
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
    ./hermes
    ./discord-bot
    ./eternal-terminal
    ./nextcloud-mcp
    # ./gotify
    ./zitadel
    # ./kanidm
    # ./syncserver
    # ./newt # attendre maj flakes
  ];
}
