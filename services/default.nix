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
    ./matrix-linkedin
    # ./matrix-telegram # attendre api_id/api_hash de my.telegram.org
    ./navidrome
    ./jellyfin
    ./tor
    # ./minio
    ./jupyterhub
    ./hermes
    ./hermes-webui
    ./hermes-dashboard
    ./hermes-pocket
    ./discord-bot
    ./discord-hermes-bridge
    ./eternal-terminal
    ./nextcloud-mcp
    ./amazon-mcp
    # ./protonmail-mcp : tower uniquement (ses options viennent du input
    # protonmail-mcp, importé par flake.nix pour tower seul). L'import ici
    # cassait l'éval de laptop/laptop-iso (option `services.protonmail-mcp`
    # inexistante chez eux). Le fichier reste importé pour tower via flake.nix.
    ./firefox-mcp
    # ./gotify
    ./zitadel
    ./zitadel-mcp
    ./roku
    ./codeberg-mcp
    ./meetup-mcp
    ./gitea
    # ./kanidm
    # ./syncserver
    # ./newt # attendre maj flakes
  ];
}
