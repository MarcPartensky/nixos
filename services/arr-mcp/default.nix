# services/arr-mcp/default.nix
# Serveur MCP arr-mcp (bardesss/arr-mcp) : couverture Radarr, Sonarr, Jellyfin,
# Prowlarr, Bazarr, etc. Exposé sur loopback, connecté par Hermes.
{ config, ... }: let
  port = 6060;
in {
  # Conteneur sorti de la conf hote : deploy/containers.nix (entree `arr-mcp`,
  # migrated = true), quadlet podman `arr-mcp.service`. Sa configuration (URL
  # et cles API des *arr) vit dans le dashboard du conteneur, pas dans nix.
  # Reprise : `just deploy arr-mcp --takeover` AVANT le switch qui retire ce
  # bloc.

  # Hermes : connexion au serveur MCP arr-mcp (transport HTTP). L'URL passe par
  # le redirecteur LAN de services/mcp-lan-access pour être cliquable depuis
  # Hermes Desktop sur le Mac ; côté tower, le trafic local repasse par lo.
  services.hermes-agent.mcpServers.arrmcp = {
    url =
      if config.services.mcp-lan-access.enable
      then "http://${config.services.mcp-lan-access.host}:${toString port}/mcp"
      else "http://127.0.0.1:${toString port}/mcp";
    timeout = 120;
  };
}
