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
    ./matrix
    ./matrix-whatsapp
    ./navidrome
    ./tor
    # ./minio
    ./jupyterhub
    ./hermes
    ./discord-bot
    ./eternal-terminal
    ./nextcloud-mcp
    ./amazon-mcp
    # ./gotify
    ./zitadel
    # ./kanidm
    # ./syncserver
    # ./newt # attendre maj flakes
  ];
}
