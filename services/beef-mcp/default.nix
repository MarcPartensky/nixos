# services/beef-mcp/default.nix
# Serveur MCP BeEF pour hermes (code dans ./server.py).
#
# Pourquoi un MCP maison : BeEF n'a qu'une console web, sans client API. Le
# module services/beef lui rend un jeton d'API REST deterministe (patch de
# core/main/crypto.rb + secret sops), ce qui permet a ce serveur de piloter la
# console en stdio : lister les navigateurs hookes, chercher un module,
# l'executer sur une session, lire le resultat.
#
# Transport stdio : hermes spawn le subprocess. Le jeton n'est jamais passe en
# clair dans la config (relu a chaque appel depuis le fichier sops, via
# BEEF_API_TOKEN_FILE) ; le secret est en 0440 beef:hermes, donc lisible par le
# service beef (owner) et par le MCP (groupe hermes).
#
# Les deux tools qui executent du code dans le navigateur de la victime
# (beef_run_module, beef_unhook) exigent confirm=True ; sans lui ils renvoient
# l'apercu de l'envoi.
#
# Debug a la main (garder stdin ouvert, un EOF tue la requete) :
#   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#     | /nix/store/.../bin/beef-mcp
{self, pkgs, config, ...}: let
  # Binaire construit comme sortie du flake (mcp/default.nix) : buildable
  # sans evaluer cette conf, et plus reconstruit a chaque eval de l'hote.
  beef-mcp = self.packages.${pkgs.stdenv.hostPlatform.system}.beef-mcp;

in {
  # Le binaire sur le PATH, et reference par mcpServers.beef.command.
  environment.systemPackages = [beef-mcp];

}
