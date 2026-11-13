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
  # Conteneur sorti de la conf hote : deploy/containers.nix (entree
  # `nextcloud-mcp`, migrated = true), quadlet podman
  # `nextcloud-mcp.service`. network=host et le cmd --host 127.0.0.1 y sont
  # repris a l'identique ; le fichier d'environnement reste le secret sops
  # ci-dessous, lu par le quadlet (/run/secrets/nextcloud_mcp_env).
  # Reprise : `just deploy nextcloud-mcp --takeover` AVANT le switch qui
  # retire ce bloc.

  # Le secret reste declare ici : c'est ce qui le rend disponible pour le
  # quadlet. restartUnits vise le nom du quadlet (plus de podman-*.service).
  sops.secrets."nextcloud_mcp_env".restartUnits = ["nextcloud-mcp.service"];

  # Hermes : transport HTTP vers le container loopback.
  # Les tools apparaissent préfixés mcp_nextcloud_* au démarrage d'hermes.
  # URL LAN (module services/mcp-lan-access) : joignable depuis tower (trafic
  # local par lo) et cliquable depuis Hermes Desktop sur le Mac du marc.
  services.hermes-agent.mcpServers.nextcloud.url =
    if config.services.mcp-lan-access.enable
    then "http://${config.services.mcp-lan-access.host}:${toString port}/mcp"
    else "http://127.0.0.1:${toString port}/mcp";
}
