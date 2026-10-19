# services/arr-mcp/default.nix
# Serveur MCP arr-mcp (bardesss/arr-mcp) : couverture Radarr, Sonarr, Jellyfin,
# Prowlarr, Bazarr, etc. Exposé sur loopback, connecté par Hermes.
{ config, ... }: let
  port = 6060;
in {
  virtualisation.oci-containers.containers.arr-mcp = {
    image = "ghcr.io/bardesss/arr-mcp:latest";
    # Port publié sur la loopback uniquement : l'accès LAN passe par le
    # redirecteur filtré de services/mcp-lan-access, jamais par le container.
    # (Avant, "6060:6060" publiait sur 0.0.0.0 et seul le firewall retenait
    # l'instance non claimée.)
    ports = [ "127.0.0.1:${toString port}:6060" ];
    # Le serveur arr-mcp doit atteindre Radarr (8086), Sonarr (8006),
    # Jellyfin (8096) et Prowlarr (8087) en loopback.
    environment = {
      # Configuration minimale : URL et clé API seront ajoutées dans
      # l'interface web du conteneur (http://tower:6060) par marc.
      # Pas de clé API dans le dépôt — l'utilisateur les configure
      # dans le dashboard du conteneur après installation.
    };
  };

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
