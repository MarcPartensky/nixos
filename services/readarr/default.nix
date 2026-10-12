{
  lib,
  pkgs,
  ...
}:
# Readarr = livres. Son dossier de données est sous /home (comme Sonarr) et son
# module ne masque pas /home, donc il fonctionne tel quel (vérifié : service
# actif, port 8088 répond 200). Seule la bibliothèque change : /srv/media/books
# (groupe `media`, cf. services/media), à sélectionner dans l'UI.
{
  services.readarr = {
    enable = true;
    user = "marc";
    group = "users";
    dataDir = "/home/marc/readarr";
    settings = {
      # update.mechanism = "internal";
      server = {
        urlbase = "localhost";
        port = 8088;
        bindaddress = "*";
      };
    };
  };

  # Média partagé : les fichiers importés doivent rester modifiables par les
  # autres membres du groupe `media`.
  systemd.services.readarr.serviceConfig.UMask = lib.mkForce "0002";
}
