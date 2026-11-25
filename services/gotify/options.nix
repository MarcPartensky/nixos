# services/gotify/options.nix
#
# Options MAISON du module services/gotify, declarees dans un fichier separe :
# default.nix porte des attributs de configuration au premier niveau
# (sops, services, systemd), il ne peut donc pas contenir aussi un attribut
# `options` (erreur fatale « has an unsupported attribute services »).
#
# Le module sert deux hotes opposes : tower (newt, cluster postgres dedie a
# gotify) et anywhere (site Pangolin `rack`, cluster postgres partage).
{ lib, ... }: {
  options.services.gotify.publishViaNewt = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Declare la ressource Pangolin via le blueprint newt (hote qui fait tourner newt).";
  };

  options.services.gotify.managePostgresAuth = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Impose les regles pg_hba de gotify (a couper sur un cluster postgres partage).";
  };
}
