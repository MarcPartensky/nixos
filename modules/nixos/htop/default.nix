# htop : colonnes et ecrans communs a la flotte, orientes diagnostic CPU/RAM
# (voir htoprc a cote pour le detail des quatre ecrans).
#
# /etc/htoprc est le dernier recours de htop : il n'est lu que par un
# utilisateur qui n'a pas de ~/.config/htop/htoprc. C'est donc la config de
# root (sudo htop sur tower, ou root direct) et des comptes neufs. Marc a le
# meme fichier en lien direct via users/marc/home.nix.
{pkgs, ...}: {
  environment.etc."htoprc".source = ./htoprc;
  environment.systemPackages = [pkgs.htop];
}
