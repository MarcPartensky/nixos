# services/arena-elo-mcp/default.nix
# Serveur MCP `arena-elo` pour hermes : les classements Elo d'Arena (ex-LMArena,
# ex-Chatbot Arena) SANS AUTHENTIFICATION, code dans ./arena-elo.py.
#
# Source unique : le dataset public lmarena-ai/leaderboard-dataset sur
# Hugging Face (CC BY 4.0), lu via l'API publique datasets-server. Aucune cle,
# aucun compte : les notes sont des fit Bradley-Terry de votes humains aveugles,
# affichees sur l'echelle Elo d'Arena avec intervalle a 95%.
#
# Pourquoi ce detour par le dataset : arena.ai n'expose ni MCP ni API publique
# et sa page leaderboard repond 403 aux clients non navigateur ; l'endpoint
# /filter de datasets-server exige une auth pour tout WHERE sur une colonne
# texte. On page donc /rows (5-6 pages par board) et on met en cache disque 6 h
# sous ARENA_ELO_CACHE. Les lignes arrivent groupees par categorie et triees par
# rang, ce qui permet d'arreter des qu'une page n'apporte plus rien.
#
# L'historique est LOCAL par construction : le split "full" upstream fait 1,1 M
# de lignes pour le texte, impossible a pager anonymement. Chaque snapshot
# publie est journalise une fois (history.jsonl) au moment ou le board est lu,
# donc la serie demarre au premier appel et grandit a chaque mise a jour.
#
# Le serveur parle JSON-RPC 2.0 sur stdio lui-meme (stdlib seule, pas de SDK
# mcp) : stdin ligne par ligne, stdout reserve au protocole, logs sur stderr.
{self, pkgs, ...}: let
  # Binaire construit comme sortie du flake (mcp/default.nix) : buildable
  # sans evaluer cette conf, et plus reconstruit a chaque eval de l'hote.
  arena-elo-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.arena-elo-mcp;
in {
  environment.systemPackages = [arena-elo-mcp];

  services.hermes-agent.mcpServers.arena-elo = {
    command = "${arena-elo-mcp}/bin/arena-elo-mcp";
    args = [];
    env = {
      ARENA_ELO_CACHE = "/var/lib/hermes/.hermes/cache/arena-elo";
    };
    # Un board froid coute 5-6 pages espacees de 0,5 s ; arena=all en scanne six.
    timeout = 180;
  };
}