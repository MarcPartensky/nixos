# services/backup-pqbox : sauvegardes chiffrées de tower, en trois étages.
#
#   pqbox.py  : outil unique, chiffrement + orchestration + transport.
#               Chiffrement : cryptography (ML-KEM-768 FIPS 203 + X25519 hybride,
#                             HKDF-SHA256, AES-256-GCM par chunks de 1 Mio,
#                             PBKDF2 1e6 pour la clé privée scellée par le mot de
#                             passe de marc).
#               Transport   : paramiko (SFTP + exec, lecture de ~/.ssh/config,
#                             ProxyJump, retries, upload atomique). Aucun
#                             appel à ssh/scp/rsync.
#
# Étage    contenu                                            cadence    rétention
#   coeur  bases vivantes + état Hermes léger (config, skills, 03:30/jour 30 rack
#          sessions, profils)                                             7 miroir
#   volume winnie, matrix-synapse, state.db, pièces jointes    dim 04:30  3
#   mortes bases abandonnées, à garder avant de les dropper    manuel     2
#
# Deux destinations, sur deux machines distinctes de tower :
#   rack : VPS, /var/backups/pqbox         (toujours, échec = échec du service)
#   mac  : Mac de marc, ~/backups-pqbox    (miroir best-effort, nœud différent)
#
# La clé publique vit dans ce dossier (backup.pub). La clé privée scellée est
# écrite par marc lui-même (setup-key.sh) dans ~/.config/pqbox/backup.key : ni
# l'agent ni les hôtes ne peuvent la lire. Sans son mot de passe, les archives
# sont indéchiffrables, y compris pour root sur tower comme sur rack.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.backup-pqbox;

  pythonEnv = pkgs.python3.withPackages (ps: [ ps.cryptography ps.paramiko ]);

  # un seul outil, pour systemd comme pour l'agent à la main
  pqbox = pkgs.writeShellScriptBin "pqbox" ''
    exec ${pythonEnv}/bin/python3 ${./pqbox.py} "$@"
  '';

  mkService = name: extra: {
    description = "Sauvegarde chiffree pqbox (${name}) vers la cle publique de marc";
    # pq_dump/pg_dump, zstd et coreutils : le reste (tar, sha256) est en Python
    path = with pkgs; [ coreutils zstd postgresql ];
    environment = {
      PUB = "${./backup.pub}";
      OUTDIR = cfg.directory;
      RACK = cfg.rack;
      MIRROR = cfg.mirror;
      KEEP_COEUR = toString cfg.keepCoeur;
      KEEP_VOLUME = toString cfg.keepVolume;
      KEEP_MORTES = toString cfg.keepMortes;
      KEEP_MIRROR = toString cfg.keepMirror;
    } // lib.optionalAttrs cfg.mirrorVolume { MIRROR_VOLUME = "1"; };
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      ExecStart = "${pqbox}/bin/pqbox backup ${name}";
      # un dump ne doit pas disputer le CPU a marc
      Nice = 10;
      IOSchedulingClass = "idle";
      IOSchedulingPriority = 7;
      CPUSchedulingPolicy = "batch";
    };
  } // extra;
in
{
  options.services.backup-pqbox = {
    enable = lib.mkEnableOption "les sauvegardes chiffrées pqbox de tower";
    directory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hermes/backups/pqbox";
      description = "Dossier des archives chiffrées.";
    };
    rack = lib.mkOption {
      type = lib.types.str;
      default = "rack:/var/backups/pqbox";
      description = "Destination principale : alias ssh et chemin.";
    };
    mirror = lib.mkOption {
      type = lib.types.str;
      default = "mac:backups-pqbox";
      description = ''
        Second dépôt, sur une AUTRE machine que tower et que le VPS. Copie
        best-effort : une machine éteinte ne fait pas échouer la sauvegarde.
        Chaîne vide = pas de miroir.
      '';
    };
    mirrorVolume = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Miroiter aussi l'étage volume (775 Mo) ; le Mac n'a que ~6 Go libres.";
    };
    keepCoeur = lib.mkOption { type = lib.types.int; default = 30; description = "Archives coeur conservées sur rack."; };
    keepVolume = lib.mkOption { type = lib.types.int; default = 3; description = "Archives volume conservées sur rack."; };
    keepMortes = lib.mkOption { type = lib.types.int; default = 2; description = "Archives mortes conservées sur rack."; };
    keepMirror = lib.mkOption { type = lib.types.int; default = 7; description = "Archives conservées sur le miroir."; };
    coeurAt = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 03:30:00";
      description = "Cadence de l'étage coeur.";
    };
    volumeAt = lib.mkOption {
      type = lib.types.str;
      default = "Sun 04:30:00";
      description = "Cadence de l'étage volume.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services = {
      backup-pqbox-coeur = mkService "coeur" { startAt = cfg.coeurAt; };
      backup-pqbox-volume = mkService "volume" { startAt = cfg.volumeAt; };
      # L'étage mortes reste manuel : il sert une fois, avant de dropper les
      # bases abandonnées. `systemctl start backup-pqbox-mortes` ou
      # `pqbox backup mortes`.
      backup-pqbox-mortes = mkService "mortes" { };
    };
  };
}
