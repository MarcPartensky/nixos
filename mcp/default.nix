# mcp/default.nix
# Les serveurs MCP maison, exposes comme sorties du flake.
#
# Pourquoi : aujourd'hui chaque serveur est construit dans le module du service
# qui le declare, donc il ne peut exister que dans la closure de
# nixosConfigurations.tower, et seulement apres un eval complet de l'hote.
# Ici chaque serveur est un paquet independant : `nix build .#shlink-mcp`
# n'evalue que nixpkgs et ce fichier, pas la conf NixOS.
#
# Ce que ca ne fait pas encore : le cablage cote module. Tant que
# services/<nom>/default.nix defini son binaire en local, l'hote ne consomme
# pas ces sorties. Le basculement se fait module par module, en pointant
# `command = "${self.packages.${pkgs.system}.<nom>}/bin/<nom>"`.
#
# Serveurs volontairement absents : ceux dont le code python est encore une
# chaine inline dans le module (androidtv-mcp, roku-mcp, pangolin-mcp, tts-mcp).
# Les sortir demande d'extraire le code dans un .py a cote d'abord.
{pkgs}: let
  py = pkgs.python3Packages;
  mk = name: file: libraries:
    pkgs.writers.writePython3Bin name {
      inherit libraries;
      flakeIgnore = ["E501" "W503" "W504"];
    } (builtins.readFile file);
in {
  shlink-mcp = mk "shlink-mcp" ../services/shlink-mcp/server.py [py.mcp];
  shorturl-mcp = mk "shorturl-mcp" ../services/shorturl-mcp/server.py [py.mcp];
  beef-mcp = mk "beef-mcp" ../services/beef-mcp/server.py [py.mcp];
  share-mcp = mk "share-mcp" ../services/share-mcp/server.py [py.mcp];
  meetup-mcp = mk "meetup-mcp" ../services/meetup-mcp/meetup_mcp.py [py.mcp];
  mac-mcp = mk "mac-mcp" ../services/mac-mcp/mac-mcp.py [py.mcp];
  ibkr-mcp = mk "ibkr-mcp" ../services/ibkr-mcp/ibkr_flex.py [py.mcp];
  arena-elo-mcp = mk "arena-elo-mcp" ../services/arena-elo-mcp/arena-elo.py [];
  username-recon = mk "username-recon" ../services/sherlock-mcp/server.py [];
}
