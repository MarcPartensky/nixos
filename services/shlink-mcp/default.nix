# services/shlink-mcp/default.nix
# Serveur MCP Shlink pour hermes (code dans ./server.py).
#
# Pourquoi un MCP maison plutôt qu'un connecteur tiers : l'API REST v3 de
# Shlink est entièrement décrite par une spec OpenAPI, donc un passthrough
# (`shlink_request`) suffit à tout piloter, plus des outils typés pour les
# opérations courantes. Aucun paquet npm, aucune dépendance exotique : le
# binaire est un script python3 + SDK `mcp`, comme pangolin-mcp et meetup-mcp.
#
# Transport stdio : hermes spawn le subprocess. La clé d'API n'est jamais
# passée en clair dans la config (elle est lue depuis le fichier sops par le
# script, via SHLINK_API_KEY_FILE).
#
# Écritures : SHLINK_ALLOW_WRITES=1 les autorise, et chaque appel mutant exige
# encore confirm=True ; sans ça l'outil renvoie un aperçu de la requête.
#
# Debug à la main (garder stdin ouvert, un EOF tue la requête) :
#   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#     | /nix/store/.../bin/shlink-mcp
{pkgs, config, ...}: let
  shlink-mcp =
    pkgs.writers.writePython3Bin "shlink-mcp" {
      libraries = [pkgs.python3Packages.mcp];
      flakeIgnore = ["E501" "W503" "W504"];
    } (builtins.readFile ./server.py);
in {
  # Le binaire sur le PATH, et référencé par mcpServers.shlink.command.
  environment.systemPackages = [shlink-mcp];

  services.hermes-agent.mcpServers.shlink = {
    command = "${shlink-mcp}/bin/shlink-mcp";
    args = [];
    env = {
      # Loopback : le conteneur shlink publie 8097 sur l'hôte (--network=host).
      SHLINK_URL = "http://127.0.0.1:8097";
      SHLINK_API_KEY_FILE = config.sops.secrets.shlink_api_key.path;
      SHLINK_ALLOW_WRITES = "1";
    };
    timeout = 60;
  };
}
