# services/backup-pqbox : sauvegardes chiffrées de tower, en trois étages.
#
#   pqbox        : outil Go (ML-KEM-768 + X25519, HKDF-SHA256, AES-256-GCM,
#                  clé privée scellée par PBKDF2 + mot de passe de marc).
#   pqbackup.sh  : construit l'archive d'un étage et la pousse sur rack.
#
# Étage    contenu                                            cadence    rétention
#   coeur  bases vivantes + état Hermes léger (config, skills, 03:30/jour 30
#          sessions, profils)
#   volume winnie, matrix-synapse, state.db, pièces jointes    dim 04:30  3
#   mortes bases abandonnées, à garder avant de les dropper    manuel     2
#
# La clé publique vit dans ce dossier (backup.pub). La clé privée scellée est
# écrite par marc lui-même (setup-key.sh) dans ~/.config/pqbox/backup.key : ni
# l'agent ni la machine hôte ne peuvent la lire. Sans son mot de passe, les
# archives sont indéchiffrables, y compris pour root sur tower comme sur rack.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.backup-pqbox;

  pqbox = pkgs.buildGoModule {
    pname = "pqbox";
    version = "1.0.0";
    src = ./.;
    vendorHash = null;
    env.CGO_ENABLED = "0";
    ldflags = [ "-s" "-w" ];
    meta = {
      description = "Dump chiffre vers une cle publique post-quantique (ML-KEM-768)";
      mainProgram = "pqbox";
    };
  };

  script = pkgs.writeShellScript "backup-pqbox" ''
    set -eu
    export PUB=${./backup.pub}
    export PQBOX=${pqbox}/bin/pqbox
    export OUTDIR=${cfg.directory}
    export RACK=${cfg.rack}
    export KEEP_COEUR=${toString cfg.keepCoeur}
    export KEEP_VOLUME=${toString cfg.keepVolume}
    export KEEP_MORTES=${toString cfg.keepMortes}
    ${lib.optionalString cfg.noRack "export NO_RACK=1"}
    exec ${pkgs.bash}/bin/bash ${./pqbackup.sh} "$1"
  '';

  mkService = name: extra: {
    description = "Sauvegarde chiffree pqbox (${name}) vers la cle publique de marc";
    path = with pkgs; [ bash coreutils inetutils gnutar zstd postgresql openssh ];
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      ExecStart = "${script} ${name}";
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
      description = "Destination distante des archives (scp).";
    };
    noRack = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Garder les archives en local seulement.";
    };
    keepCoeur = lib.mkOption { type = lib.types.int; default = 30; description = "Archives coeur conservées."; };
    keepVolume = lib.mkOption { type = lib.types.int; default = 3; description = "Archives volume conservées."; };
    keepMortes = lib.mkOption { type = lib.types.int; default = 2; description = "Archives mortes conservées."; };
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
      # `./pqbackup.sh mortes`.
      backup-pqbox-mortes = mkService "mortes" { };
    };
  };
}
