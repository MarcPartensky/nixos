# services/sherlock-mcp/default.nix
# MCP `username-recon` pour hermes : enumere les comptes publics d'un username
# ou d'un email, code dans ./server.py.
#
# Un serveur par CAPACITE, pas un serveur par outil : les trois moteurs
# (sherlock 414 sites, maigret 3155 sites avec parsing de profil, socialscan
# 11 plateformes par sondage des endpoints d'inscription) sont derriere un seul
# jeu de tools, et le choix du moteur est une decision du serveur (`engines=auto`
# fait sherlock puis bascule, `engines=all` fait l'union), pas un raisonnement a
# refaire a chaque conversation.
#
# Ce que le serveur ajoute aux moteurs nus : le CONTROLE NEGATIF. Chaque moteur
# est relance avec un username impossible, et tout site qui le declare existant
# est rendu `unreliable` au lieu d'etre presente comme un hit. C'est la reponse
# au defaut structurel de Sherlock (un site qui repond 200 sur tout est annonce
# « Claimed » pour n'importe quoi). Mesure du 2026-11-11 : 5 sites bruyants pour
# sherlock, 13 pour maigret, sur un username aleatoire. Le resultat est cache
# sous SHERLOCK_MCP_STATE (TTL 72 h) : une passe complete coute 1 a 2 minutes,
# on ne la refait pas a chaque scan.
#
# Le binaire embarque les moteurs dans son PATH et l'etat sous /var/lib/hermes
# (ProtectSystem=strict : un sous-processus MCP ne peut ecrire que la). L'etat
# comprend aussi une copie inscriptible de la base de maigret : le paquet
# nixpkgs reecrit sa base a la sortie et meurt en PermissionError sur le store.
#
# Debug a la main (garder stdin ouvert, un EOF tue la requete en vol) :
#   { printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n'; sleep 5; } \
#     | /nix/store/.../bin/username-recon-hermes
{self, pkgs, lib, ...}: let
  # Binaire construit comme sortie du flake (mcp/default.nix) : buildable
  # sans evaluer cette conf, et plus reconstruit a chaque eval de l'hote.
  username-recon = self.packages.${pkgs.stdenv.hostPlatform.system}.username-recon;

  wrapper = pkgs.writeShellScript "username-recon-hermes" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [pkgs.sherlock pkgs.maigret pkgs.socialscan]
    }:$PATH
    export SHERLOCK_MCP_STATE=/var/lib/hermes/.hermes/cache/username-recon
    exec ${username-recon}/bin/username-recon
  '';
in {
  environment.systemPackages = [username-recon];

  services.hermes-agent.mcpServers.username-recon = {
    command = "${wrapper}";
    args = [];
    # Un balayage sherlock complet fait 60 a 90 s, maigret environ 1 min, et un
    # scan `engines=all` avec controle negatif froid atteint 2 a 3 min.
    timeout = 900;
  };
}
