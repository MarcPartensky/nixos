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
    ./cage-firefox
    # ./dnscrypt
    ./adguard
    ./matrix
    ./matrix-whatsapp
    ./matrix-signal
    ./matrix-discord
    ./matrix-meta
    # ./matrix-telegram # attendre api_id/api_hash de my.telegram.org
    ./navidrome
    ./tor
    # ./minio
    ./jupyterhub
    ./hermes
    ./discord-bot
    ./eternal-terminal
    ./nextcloud-mcp
    ./amazon-mcp
    ./protonmail-mcp
    ./firefox-mcp
    # ./gotify
    ./zitadel
    ./zitadel-mcp
    ./roku
    ./codeberg-mcp
    # ./kanidm
    # ./syncserver
    # ./newt # attendre maj flakes
  ];
}
