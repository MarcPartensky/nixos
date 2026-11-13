# services/immich/default.nix
# Immich : l'interface photos/videos (timeline, visages, recherche, carte,
# applis mobiles). Verdict du comparatif SOTA : c'est l'etat de l'art, 119k
# etoiles, release v3.4.1 upstream.
#
# PAQUET : celui du pin 26.05 est immich 2.7.5, marque `insecure` par nixpkgs
# (deux CVE : CVE-2026-59258, CVE-2026-82272, et 2.x ne recoit plus de
# correctifs). On prend donc immich 3.2.2 depuis l'input `unstable` du flake :
# le module nixpkgs 26.05 pilote le paquet sans probleme (memes variables
# d'environnement, passthru `machine-learning` present).
#
# Architecture decidee : la SOURCE DE VERITE reste l'arbre ZFS
# /home/marc/media/photos (dataset `nixos/marc/media`), Garage en est le miroir
# de sauvegarde, et Immich ne fait que L'INDEXER via une bibliotheque externe.
# Aucune copie, aucun reupload : Immich n'a pas de backend S3 (feature request
# #30191 toujours ouverte), donc « Immich avec Garage en backend » n'existe pas.
#
# L'arbre est expose aux services par un bind READ-ONLY sur /srv/photos :
#   - /home est protege (ProtectHome=true) dans les unites systemd, un bind
#     explicite sur /srv contourne ca proprement ;
#   - le mode ro garantit qu'aucune appli ne peut ecrire dans l'arbre partage
#     avec Syncthing et le miroir Garage (pas de sidecar, pas de vignette).
#
# Droits : les dossiers sont 2770 marc:photos et les fichiers hermes:photos,
# donc l'utilisateur `immich` est ajoute au groupe `photos` pour lire.
# PrivateUsers est desactive sur immich-server uniquement : sous PrivateUsers,
# l'appartenance a un groupe hote n'est pas mappee et la lecture echouerait.
#
# Ressources : ML (visages, recherche) active, sur CPU. tower n'a ni CUDA ni
# ROCm. Le service tourne en Slice system-immich.slice, donc separable et
# mesurable (systemd-cgtop -M system-immich.slice).
{ config, lib, pkgs, inputs, ... }:
let
  photosSource = "/home/marc/media/photos";
  photosMount = "/srv/photos";
in
{
  fileSystems."${photosMount}" = {
    device = photosSource;
    fsType = "none";
    options = [
      "bind"
      "ro"
      "x-systemd.requires-mounts-for=${photosSource}"
    ];
  };

  users.users.immich.extraGroups = [ "photos" ];

  services.immich = {
    enable = true;
    host = "127.0.0.1";
    port = 2283;
    package = inputs.unstable.legacyPackages.${pkgs.system}.immich;
    # Bibliotheque propre d'Immich (uploads depuis l'appli mobile, vignettes,
    # videos transcodees). Sur le pool racine (191 Go libres) et non sur le
    # dataset media, dont le quota de 150 G doit rester aux photos.
    mediaLocation = "/var/lib/immich";
    database.enable = true;
    redis.enable = true;
    machine-learning.enable = true;
    environment = {
      TZ = "America/New_York";
      # Pas de telemetrie vers l'exterieur.
      IMMICH_TELEMETRY_INCLUDE = "none";
    };
  };

  # Immich lit un dossier, il n'a aucun endpoint S3 : la bibliotheque externe
  # se declare dans l'UI (Administration > External Libraries) sur /srv/photos.
  systemd.services.immich-server.serviceConfig = {
    PrivateUsers = lib.mkForce false;
    BindReadOnlyPaths = [ "${photosMount}:/srv/photos" ];
  };
}
