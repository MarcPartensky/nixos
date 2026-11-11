# services/photos/default.nix
# Photos du telephone (camera, WhatsApp, Messenger) : arborescence locale sur le
# dataset ZFS `nixos/marc/media` (monte sur /home/marc/media) + miroir S3 dans
# Garage, un bucket par source.
#
# POURQUOI un dataset et pas un dossier de plus : quota qui empeche les photos
# de remplir le pool (tower est a 76 %), snapshots independants du reste du home
# (services.zfs.autoSnapshot les prend separement), et proprietaire controlable.
# /home/marc/media est en root:root 0755 a l'installation (disko), donc le
# service Syncthing qui tourne en marc ne pourrait PAS y ecrire : l'activation
# ci-dessous repasse l'arbre en marc:users.
#
# Deux chemins d'entree, parce que Android ne laisse aucun shell lire
# /storage/emulated/0 (scoped storage) :
#   1. adb (le stock initial) : `scripts/photos-pull.sh` (hermes) ecrit
#      directement dans l'arbre, source par source.
#   2. Syncthing (le continu) : dossiers declares cote tower et cote tel.
# Les deux ecrivent dans le meme arbre, d'ou le groupe `photos` (marc + hermes)
# en 2770 setgid : chacun ecrit, et les fichiers crees restent lisibles par
# l'autre. Pas de dossier de staging ni d'unite root pour deplacer les fichiers.
#
# Le miroir S3 est un `rclone sync` horaire : la source de verite reste le
# dataset, Garage est la copie objet (et ce que d'autres outils lisent en S3).
# `scripts/photos-status.sh` compare l'arbre local et les buckets.
{ config, lib, pkgs, ... }:
let
  garageState = "/var/lib/garage";
  photosRoot = "/home/marc/media/photos";

  # source locale -> bucket Garage. Le S3 n'a pas de dossiers : un bucket par
  # source pour pouvoir isoler, compter et sauvegarder chacune separement.
  sources = {
    camera = "photos-camera";
    whatsapp = "photos-whatsapp";
    messenger = "photos-messenger";
  };
in
{
  # Groupe partage de l'arbre photos : marc (Syncthing) et hermes (adb pull).
  users.groups.photos = {
    members = [ "marc" "hermes" ];
  };

  # Arborescence + proprietaire + quota du dataset. Idempotent : tourne a chaque
  # switch, ne touche a rien si c'est deja en place.
  system.activationScripts.photos-tree = ''
    install -d -m 2770 -o marc -g photos ${photosRoot}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
      name: _: "install -d -m 2770 -o marc -g photos ${photosRoot}/${name}"
    ) sources)}
    # Quota : 150 G sur le dataset media. Le pool a ~206 G libres, et ZFS
    # ralentit au-dela de 80-85 % d'occupation : mieux vaut un refus d'ecriture
    # qu'un pool en souffrance. Idempotent (zfs set reecrit la meme valeur).
    ${pkgs.zfs}/bin/zfs set quota=150G nixos/marc/media 2>/dev/null || true
  '';

  # Miroir S3 : un rclone sync par source, avec les identifiants generes par
  # garage-bootstrap. Les echecs sont signales mais ne font pas echouer le
  # service : la copie S3 est une redondance, pas la source de verite.
  systemd.services.photos-to-garage = {
    description = "Miroir S3 des photos vers Garage (un bucket par source)";
    after = [ "garage.service" ];
    wants = [ "garage.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
    path = [ pkgs.rclone pkgs.coreutils ];
    script = ''
      set -eu
      if [ ! -s ${garageState}/s3-key.env ]; then
        echo "photos-to-garage : pas d'identifiants Garage, rien a faire" >&2
        exit 0
      fi
      set -a
      . ${garageState}/s3-key.env
      set +a
      export RCLONE_CONFIG_GARAGE_TYPE=s3
      export RCLONE_CONFIG_GARAGE_PROVIDER=Other
      export RCLONE_CONFIG_GARAGE_ENDPOINT=http://127.0.0.1:3900
      export RCLONE_CONFIG_GARAGE_REGION=garage
      export RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
      export RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (src: bucket: ''
        if [ -d ${photosRoot}/${src} ]; then
            rclone sync ${photosRoot}/${src} garage:${bucket} \
              --transfers 4 --checkers 8 \
              --exclude '.thumbnails/**' --exclude '*.tmp' --exclude '.nomedia' \
              || echo "photos-to-garage : ${src} a echoue" >&2
          fi
      '') sources)}
    '';
  };

  systemd.timers.photos-to-garage = {
    description = "Miroir S3 horaire des photos vers Garage";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = 300;
    };
  };

  # rclone en CLI pour hermes : verifier les buckets sans attendre qu'il soit
  # dans le PATH systeme (il n'y est pas).
  environment.systemPackages = [ pkgs.rclone ];
}
