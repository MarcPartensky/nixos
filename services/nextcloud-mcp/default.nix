# services/nextcloud-mcp/default.nix
# Serveur MCP Nextcloud (cbcoutinho/nextcloud-mcp-server) en mode single_user_basic,
# exposé en streamable-http sur loopback ; Hermes s'y connecte en HTTP.
#
# Auth : mot de passe d'application Nextcloud (Paramètres -> Sécurité -> Appareils
# & sessions), pas le mot de passe de login. Docs : docs/authentication.md du repo.
#
# Secret sops (secrets/tower.yml) :
#   nextcloud_mcp_env: |
#     NEXTCLOUD_USERNAME=ton_user
#     NEXTCLOUD_PASSWORD=ton_app_password
#
# Debug :
#   journalctl -u podman-nextcloud-mcp.service -f   (ou docker- selon le backend)
#   curl http://127.0.0.1:8710/health/ready
{config, ...}: let
  port = 8710;
in {
  virtualisation.oci-containers.containers.nextcloud-mcp = {
    image = "ghcr.io/cbcoutinho/nextcloud-mcp-server:latest"; # épingler un tag une fois validé
    # network=host : Nextcloud est sur 127.0.0.1:8083 (trusted_domains) ; depuis
    # le netns du container, 127.0.0.1 ne pointe pas vers l'hôte et l'IP du
    # bridge podman0 n'est pas dans trusted_domains (400 Nextcloud).
    extraOptions = ["--network=host"];
    # Pas de --enable-app : par défaut TOUTES les apps sont exposées (notes,
    # webdav/fichiers, calendar, contacts, deck, tables, sharing, news,
    # collectives...) — c'est ce qui donne les tools d'écriture
    # (nc_notes_create_note, nc_webdav_write_file, etc.). Pour restreindre :
    # répéter "--enable-app" "<app>" (cf. docs/running.md du repo upstream).
    cmd = ["--host" "127.0.0.1" "--port" (toString port)];
    environment = {
      # Nextcloud tourne sur tower (nginx :8083) ; l'URL publique passe par
      # Pangolin (SSO) qui redirige status.php -> on tape directement le local.
      NEXTCLOUD_HOST = "http://127.0.0.1:8083";
      MCP_DEPLOYMENT_MODE = "single_user_basic";
    };
    environmentFiles = [config.sops.secrets."nextcloud_mcp_env".path];
  };

  sops.secrets."nextcloud_mcp_env".restartUnits = [
    "${config.virtualisation.oci-containers.backend}-nextcloud-mcp.service"
  ];

  # Hermes : transport HTTP vers le container loopback.
  # Les tools apparaissent préfixés mcp_nextcloud_* au démarrage d'hermes.
  # URL LAN (module services/mcp-lan-access) : joignable depuis tower (trafic
  # local par lo) et cliquable depuis Hermes Desktop sur le Mac du marc.
  services.hermes-agent.mcpServers.nextcloud.url =
    if config.services.mcp-lan-access.enable
    then "http://${config.services.mcp-lan-access.host}:${toString port}/mcp"
    else "http://127.0.0.1:${toString port}/mcp";
}
