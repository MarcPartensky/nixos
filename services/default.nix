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
    ./matrix-marc-agent
    # ./matrix-telegram # attendre api_id/api_hash de my.telegram.org
    ./navidrome
    ./jellyfin
    ./audiobookshelf
    ./media
    ./arr-mcp
    ./tor
    # ./minio
    ./jupyterhub
    ./hermes
    ./hermes-webui
    ./hermes-dashboard
    ./hermes-pocket
    ./discord-bot
    # ./discord-hermes-bridge  # inutile : un seul gateway par hote, celui du
    # profil default sert deja le profil discord-bridge (l'unite faisait
    # crash-looper un second gateway, exit 75 « The host gateway already serves
    # profile 'discord-bridge' »). Le cog Discord tape la route multiplexee
    # http://127.0.0.1:8642/p/discord-bridge/v1/chat/completions.
    ./eternal-terminal
    ./nextcloud-mcp
    ./amazon-mcp
    ./firefox-mcp
    # ./stalwart-mcp  # FIXME: cargoHash mismatch, needs fix
    # ./gotify
    ./zitadel
    # ./zitadel-mcp  # FIXME: secret zitadel_mcp_env manquant dans zitadel.yml
    ./roku
    ./codeberg-mcp
    ./ibkr-mcp
    # ./vaultwarden-mcp  # FIXME: missing input
    ./meetup-mcp
    ./gitea
    ./gitea-mcp
    ./openrouter-mcp
    ./reactive-resume
    ./anki-sync-server
    ./winnie
    # ./kanidm
    # ./syncserver
    # ./newt # attendre maj flakes

    # Remote desktop gateway & access (WIP, non activé sur aucun profil : les
    # modules définissent juste les options, `enable` reste à false partout.
    # Domaines/secrets encore en placeholder dans les modules, cf TODO internes.)
    ../modules/nixos/vault-rustguac
    ../modules/nixos/rustguac
    ../modules/nixos/kasmvnc
    ../modules/nixos/rustdesk
    ../modules/nixos/nginx/rustguac
    ../modules/nixos/nginx/kasmvnc
  ];
}
