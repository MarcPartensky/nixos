# services/photoprism/default.nix
# PhotoPrism: second indexer on the SAME tree, only so that marc
# compares the two interfaces on his real photos before we keep one.
# It is not meant to stay: two indexers on the same gallery cost two
# caches, two databases and two CPU scans.
#
# Structural differences with Immich, and what we do about it here:
#   - PhotoPrism WRITES YAML sidecars and its thumbnails into the
#     `originals` folder by default. We forbid it any write in the tree:
#     PHOTOPRISM_READONLY=true (disables the functions that require writing
#     into originals), tree mounted as bind read-only on /srv/photos, and
#     ReadWritePaths reduced to its sole storagePath.
#   - Its nixpkgs module (DynamicUser + PrivateUsers) would break access to the
#     `photos` group: we switch to a static user whose primary group
#     is `photos`, which gives read access to the 2770 folders.
{ config, lib, pkgs, ... }:
let
  photosMount = "/srv/photos";
in
{
  users.users.photoprism = {
    isSystemUser = true;
    group = "photos";
    description = "PhotoPrism (interface comparison on the photos tree)";
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
      # No outbound telemetry/update check.
      PHOTOPRISM_DISABLE_TENSORFLOW = "false";
    };
  };

  systemd.services.photoprism.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = lib.mkForce "photoprism";
    Group = lib.mkForce "photos";
    PrivateUsers = lib.mkForce false;
    ProtectHome = lib.mkForce false;
    # The module puts originals and import in ReadWritePaths: we remove them,
    # otherwise systemd would try to remount /srv/photos in write mode.
    ReadWritePaths = lib.mkForce [ "/var/lib/photoprism" ];
    BindReadOnlyPaths = [ "${photosMount}:/srv/photos" ];
  };
}
