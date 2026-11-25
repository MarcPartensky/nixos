# services/shlink-mcp/default.nix
# Serveur MCP Shlink pour hermes (portage Rust, crate dans ../../mcp/shlink-mcp-rs).
#
# Pourquoi un MCP maison plutôt qu'un connecteur tiers : l'API REST v3 de
# Shlink est entièrement décrite par une spec OpenAPI, donc un passthrough
# (`shlink_request`) suffit à tout piloter, plus des outils typés pour les
# opérations courantes.
#
# Pourquoi Rust et plus Python : même contrat JSON-RPC, mêmes 10 outils, mêmes
# réponses (parité vérifiée sur 9 appels réels le 15/11/2026), pour 1,4 Mo de
# RSS au lieu de 54 Mo, 2 ms de démarrage au lieu de 4,2 s, et un texte de
# réponse compact (1,4 ko au lieu de 2,4 ko sur shlink_list_short_urls).
# L'ancien server.py FastMCP a été supprimé en même temps.
#
# Transport stdio : hermes spawn le subprocess. La clé d'API n'est jamais
# passée en clair dans la config (elle est lue depuis le fichier sops par le
# binaire, via SHLINK_API_KEY_FILE).
#
# Écritures : SHLINK_ALLOW_WRITES=1 les autorise, et chaque appel mutant exige
# encore confirm=True ; sans ça l'outil renvoie un aperçu de la requête.
#
# Debug à la main (garder stdin ouvert, un EOF tue la requête) :
#   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#     | /nix/store/.../bin/shlink-mcp-rs
{self, pkgs, config, ...}: let
  # Binaire construit comme sortie du flake (mcp/default.nix) : buildable
  # sans evaluer cette conf.
  shlink-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.shlink-mcp;

in {
  # Le binaire sur le PATH.
  environment.systemPackages = [shlink-mcp];

  # Déclaration stdio : ce serveur n'est plus monté par mcp-host
  # (services.mcp-host.servers ne le liste plus), donc ses outils reviennent
  # sous le namespace mcp__shlink__* au lieu de hermes-tools.
  services.hermes-agent.mcpServers.shlink = {
    command = "${shlink-mcp}/bin/shlink-mcp-rs";
    args = [];
    env = {
      SHLINK_URL = "http://127.0.0.1:8097";
      SHLINK_API_KEY_FILE = config.sops.secrets.shlink_api_key.path;
      SHLINK_ALLOW_WRITES = "1";
    };
    timeout = 120;
  };
}
