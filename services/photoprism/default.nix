# services/photoprism/default.nix
# PhotoPrism : second indexeur sur le MEME arbre, uniquement pour que marc
# compare les deux interfaces sur ses vraies photos avant qu'on en garde une.
# Il n'est pas cense rester : deux indexeurs sur la meme galerie coutent deux
# caches, deux bases et deux scans CPU.
#
# Differences structurelles avec Immich, et ce qu'on en fait ici :
#   - PhotoPrism ECRIT des sidecars YAML et ses vignettes dans le dossier
#     `originals` par defaut. On lui interdit toute ecriture dans l'arbre :
#     PHOTOPRISM_READONLY=true (desactive les fonctions qui exigent d'ecrire
#     dans originals), arbre monte en bind read-only sur /srv/photos, et
#     ReadWritePaths reduit a son seul storagePath.
#   - Son module nixpkgs (DynamicUser + PrivateUsers) casserait l'acces au
#     groupe `photos` : on passe sur un utilisateur statique dont le groupe
#     primaire est `photos`, ce qui donne la lecture des dossiers 2770.
{ config, lib, pkgs, ... }:
let
  photosMount = "/srv/photos";
in
{
  users.users.photoprism = {
    isSystemUser = true;
    group = "photos";
    description = "PhotoPrism (comparatif d'interface sur l'arbre photos)";
  };

  services.photoprism = {
    enable = true;
    address = "127.0.0.1";
    port = 2342;
    originalsPath = photosMount;
    storagePath = "/var/lib/photoprism";
    settings = {
      PHOTOPRISM_READONLY = "true";
      PHOTOPRISM_DISABLE_CHOWN = "true";
      PHOTOPRISM_DEFAULT_LOCALE = "fr";
      PHOTOPRISM_SITE_TITLE = "PhotoPrism";
      # Pas de telemetrie/update check sortant.
      PHOTOPRISM_DISABLE_TENSORFLOW = "false";
    };
  };

  systemd.services.photoprism.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = lib.mkForce "photoprism";
    Group = lib.mkForce "photos";
    PrivateUsers = lib.mkForce false;
    ProtectHome = lib.mkForce false;
    # Le module met originals et import dans ReadWritePaths : on les retire,
    # sinon systemd tenterait de remonter /srv/photos en ecriture.
    ReadWritePaths = lib.mkForce [ "/var/lib/photoprism" ];
    BindReadOnlyPaths = [ "${photosMount}:/srv/photos" ];
  };
}
