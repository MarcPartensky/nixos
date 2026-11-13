{
  pkgs,
  config,
  ...
}: {
  imports = [
    ./nextcloud
    ./cpu-priority
    ./postgres
    # Labo de hook navigateur (BeEF) : console d'operateur sur
    # beef.marcpartensky.com (SSO Pangolin), leurre diffuse par un tunnel rapide
    # Cloudflare. Le module porte les trois unites (filtre, tunnel, beef) et la
    # ressource Pangolin. Voir services/beef/default.nix.
    ./beef
    # Les serveurs MCP maison (beef, shlink, shorturl, meetup, mac, roku...) ne
    # sont PAS importes ici : leur code est monte par modules/nixos/mcp-host
    # depuis les fichiers .py, et leur binaire reste disponible en sortie de
    # flake (`nix build .#shlink-mcp`). Les garder en module ne leur ajoutait
    # qu'un `environment.systemPackages`, donc une evaluation de paquet a
    # chaque eval de l'hote pour un binaire que personne n'appelait plus.
    # Un MCP maison encore en stdio (arena-elo, username-recon, share, tts)
    # garde son module : c'est sa declaration mcpServers qui le rend vivant.
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
    # Agregateur de flux camera (tablette, tel...) et page web a plusieurs flux
    # sur cam.marcpartensky.com. Voir services/go2rtc/default.nix.
    ./go2rtc
    # Comparaison de plateformes de documentation (5 générateurs statiques +
    # Wiki.js 3 sur wiki.marcpartensky.com, OIDC Zitadel).
    ./docs-compare
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
    # Terminal web REEL sur terminal.marcpartensky.com (ttyd + session zellij
    # persistante, SSO Pangolin). C'est ce domaine qui servait avant le panneau
    # d'admin Hermes, deplace sur dash.marcpartensky.com.
    ./terminal
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
    # Pont Gotify <-> Matrix (salle « 🪽 Hermes ») : relais gotify-matrix-relay
    # + provisionnement des jetons Gotify. Le hook Matrix -> Gotify est lui
    # vendorise dans services/hermes/hooks. Voir le module pour les pieges E2EE.
    ./gotify-matrix
    ./zitadel
    # ./zitadel-mcp  # FIXME: secret zitadel_mcp_env manquant dans zitadel.yml
    # ./roku
    # Module mort : son unique contenu etait `mcpServers.roku` en stdio, et
    # services/roku/ est en lecture seule pour l'agent (mask r--), donc il n'a
    # pas pu etre vide. Le serveur vit maintenant dans services/roku-mcp.py,
    # monte par modules/nixos/mcp-host. A supprimer le jour ou l'ACL redevient
    # inscriptible ; l'import est commente pour qu'il ne revienne pas.
    ./codeberg-mcp
    ./ibkr-mcp
    # ./vaultwarden-mcp  # prêt et testé (binaire + wrapper + secret) : à
    # décommenter lors d'un rebuild où couper hermes-agent ne gêne pas, car
    # ajouter un mcpServer régénère hermes-config.yaml et redémarre le gateway.
    # En attendant, l'accès passe par ~/.hermes/scripts/vault-get.sh (CLI bw).
    ./gitea
    ./gitea-mcp
    ./openrouter-mcp
    ./reactive-resume
    ./open-notebook
    # Shlink : raccourcisseur d'URL (s.marcpartensky.com) + son MCP hermes.
    ./shlink
    # Console d'admin de Shlink (PWA officielle) sur shlink.marcpartensky.com,
    # derriere le SSO Pangolin.
    ./shlink-web-client
    # Partage de fichiers par lien court : bucket public Garage exposé en
    # files.marcpartensky.com + MCP `share` (S3 -> Shlink -> façade x.gd).
    ./share-mcp
    # Classements Elo d'Arena (ex-LMArena) sans auth, lus depuis le dataset
    # public lmarena-ai/leaderboard-dataset (CC BY 4.0). MCP hermes "arena-elo".
    ./arena-elo-mcp
    # Garage : S3 pour les artifacts de build (remplace rustfs, retire pour son
    # CPU au repos) + MCP S3 cote hermes.
    ./garage
    # Photos du telephone (camera, WhatsApp, Messenger) : arborescence sur le
    # dataset media + miroir S3 dans Garage, un bucket par source.
    ./photos
    ./anki-sync-server
    ./anki-mcp
    # Winnie n'est PLUS dans la conf hote (decision marc du 13/11) : le module
    # lisait le flake du projet avec `builtins.getFlake`, ce qui forcait Nix a
    # relire et hacher les 16 Go de son arbre de travail (11,5 Go de*/target/,
    # 72 570 fichiers) a CHAQUE evaluation : eval de tower a 863 s mesuree.
    # C'est aussi ce getFlake, et lui seul, qui rendait --impure obligatoire.
    #
    # Attention : un switch qui part de cet etat RETIRE les unites winnie
    # (backend, front, dev, ingest, schema, bucket, jwt-secret) et son
    # provisionnement Postgres. Winnie doit donc etre redeploye hors de la conf
    # hote AVANT le prochain switch (meme schema que deploy/containers.nix).
    # ./winnie
    ./wise-mcp
    ./bank-mcp
    # Enumeration de comptes par username / email (sherlock + maigret +
    # socialscan) avec controle negatif : MCP hermes "username-recon".
    ./sherlock-mcp
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
