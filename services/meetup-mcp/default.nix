# services/meetup-mcp/default.nix
# Serveur MCP Meetup pour hermes : recherche d'events et de groupes publics
# via l'API GraphQL de Meetup (https://api.meetup.com/gql-ext), transport
# stdio (hermes spawn le subprocess, pas d'unité systemd).
#
# Auth : AUCUNE requise pour ce périmètre. Vérifié le 26/09/2026 sans token :
# eventSearch, groupSearch, event, events, groupByUrlname, recommendedEvents,
# recommendedGroups, suggestTopics, topicCategories répondent tous. Les
# requêtes nominatives (self, RSVPs personnels, publication d'events) exigent
# un OAuth consumer, que seul un compte Meetup Pro peut créer. Si un token
# arrive un jour : le poser dans secrets/meetup.yml (clé meetup_oauth_token),
# le déclarer en sops.secrets ici (owner/group hermes, mode 0400,
# restartUnits hermes-agent) et le serveur le lira via MEETUP_TOKEN_FILE,
# sans changement de code (fichier absent = mode public).
#
# Le code du serveur vit dans meetup_mcp.py à côté (testable isolément) ;
# writers.writePython3Bin le passe au lint (pycodestyle/pyflakes) au build.
#
# Debug : { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#   | /nix/store/.../bin/meetup-mcp   (garder stdin ouvert : un EOF tue la requête)
{pkgs, ...}: let
  meetup-mcp =
    pkgs.writers.writePython3Bin "meetup-mcp" {
      libraries = [pkgs.python3Packages.mcp];
      flakeIgnore = ["E501" "W503" "W504"];
    } (builtins.readFile ./meetup_mcp.py);
in {
  services.hermes-agent.mcpServers.meetup = {
    command = "${meetup-mcp}/bin/meetup-mcp";
    env = {
      MEETUP_API_URL = "https://api.meetup.com/gql-ext";
      # Optionnel : token OAuth (fichier absent = mode public).
      MEETUP_TOKEN_FILE = "/run/secrets/meetup_oauth_token";
    };
  };
}
