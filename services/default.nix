{
  pkgs,
  config,
  ...
}: {
  imports = [
    ./nextcloud
    ./cpu-priority
    ./postgres
    # Sauvegardes chiffrées de tower (pqbox : ML-KEM-768) : trois étages,
    # timers coeur (quotidien) et volume (hebdomadaire). Détail dans le module.
    ./backup-pqbox
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
    ./cage-waydroid
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
    ./aonsoku.nix
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
    ./hermes-mobile
    ./discord-bot
    # ./discord-hermes-bridge  # inutile : un seul gateway par hote, celui du
    # profil default sert deja le profil discord-bridge (l'unite faisait
    # crash-looper un second gateway, exit 75 « The host gateway already serves
    # profile 'discord-bridge' »). Le cog Discord tape la route multiplexee
    # http://127.0.0.1:8642/p/discord-bridge/v1/chat/completions.
    ./eternal-terminal
    ./nextcloud-mcp
    ./mcp-lan-access
    ./amazon-mcp
    ./hinge-auto
    ./firefox-mcp
    # ./stalwart-mcp  # importé par profiles/tower uniquement (voir le commentaire
    # dans le module : sur anywhere la clé sops entre en conflit avec services/stalwart)
    ./gotify
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
    ./open-notebook
    # Shlink : raccourcisseur d'URL (s.marcpartensky.com) + son MCP hermes.
    ./shlink
    ./shlink-mcp
    # Partage de fichiers par lien court : bucket public Garage exposé en
    # files.marcpartensky.com + MCP `share` (S3 -> Shlink -> façade x.gd).
    ./share-mcp
    # Garage : S3 pour les artifacts de build (remplace rustfs, retire pour son
    # CPU au repos) + MCP S3 cote hermes.
    ./garage
    # Photos du telephone (camera, WhatsApp, Messenger) : arborescence sur le
    # dataset media + miroir S3 dans Garage, un bucket par source.
    ./photos
    ./anki-sync-server
    ./anki-mcp
    ./mac-mcp
    ./wise-mcp
    ./bank-mcp
    ./llm-steamdeck
    ./android-capture
    # ./kanidm
    # ./syncserver
    # ./newt # attendre maj flakes

    # Remote desktop gateway & access (WIP, non activé sur aucun profil : les
    # modules définissent juste les options, `enable` reste à false partout.
    # Domaines/secrets encore en placeholder dans les modules, cf TODO internes.)
    ../modules/nixos/vault-rustguac
    ../modules/nixos/rustguac
    ../modules/nixos/kasmvnc
    ../modules/nixos/kasmvnc-chrome-cdp.nix
    ../modules/nixos/rustdesk
    ../modules/nixos/nginx/rustguac
    ../modules/nixos/nginx/kasmvnc
  ];
}
