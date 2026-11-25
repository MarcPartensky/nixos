# services/backup-pqbox: encrypted backups of tower, in three tiers.
#
#   pqbox.py  : single tool, encryption + orchestration + transport.
#               Encryption: cryptography (ML-KEM-768 FIPS 203 + X25519 hybrid,
#                             HKDF-SHA256, AES-256-GCM in 1 MiB chunks,
#                             PBKDF2 1e6 for the private key sealed by marc's
#                             passphrase).
#               Transport  : paramiko (SFTP + exec, reads ~/.ssh/config,
#                             ProxyJump, retries, atomic upload). No
#                             call to ssh/scp/rsync.
#
# Tier     content                                            cadence    retention
#   coeur  live databases + light Hermes state (config, skills, 03:30/day 30 rack
#          sessions, profiles)                                             7 mirror
#   volume winnie, matrix-synapse, state.db, attachments       Sun 04:30  3
#   mortes abandoned databases, to keep before dropping them   manual     2
#
# Two destinations, on two machines distinct from tower:
#   rack : VPS, /var/backups/pqbox         (always, failure = service failure)
#   mac  : marc's Mac, ~/backups-pqbox    (best-effort mirror, different node)
#
# The public key lives in this folder (backup.pub). The sealed private key is
# written by marc himself (setup-key.sh) into ~/.config/pqbox/backup.key: neither
# the agent nor the hosts can read it. Without his passphrase, the archives
# are undecipherable, including for root on tower as on rack.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.backup-pqbox;

  pythonEnv = pkgs.python3.withPackages (ps: [ ps.cryptography ps.paramiko ]);

  # a single tool, for systemd as for the agent by hand
  pqbox = pkgs.writeShellScriptBin "pqbox" ''
    exec ${pythonEnv}/bin/python3 ${./pqbox.py} "$@"
  '';

  mkService = name: extra: {
    description = "Encrypted pqbox backup (${name}) to marc's public key";
    # pq_dump/pg_dump, zstd and coreutils: the rest (tar, sha256) is in Python
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
      PG_REMOTE_HOST = cfg.pgRemoteHost;
      STATE_REMOTE_HOST = cfg.stateRemoteHost;
      HERMES_REMOTE_DIR = cfg.hermesRemoteDir;
      SKIP_IF_FRESH = toString cfg.skipIfFresh;
    } // lib.optionalAttrs cfg.mirrorVolume { MIRROR_VOLUME = "1"; };
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      ExecStart = "${pqbox}/bin/pqbox backup ${name}";
      # a dump must not compete for the CPU with marc
      Nice = 10;
      IOSchedulingClass = "idle";
      IOSchedulingPriority = 7;
      CPUSchedulingPolicy = "batch";
    };
  } // extra;
in
{
  options.services.backup-pqbox = {
    enable = lib.mkEnableOption "the encrypted pqbox backups of tower";
    directory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hermes/backups/pqbox";
      description = "Folder of the encrypted archives.";
    };
    rack = lib.mkOption {
      type = lib.types.str;
      default = "rack:/var/backups/pqbox";
      description = "Main destination: ssh alias and path.";
    };
    mirror = lib.mkOption {
      type = lib.types.str;
      default = "mac:backups-pqbox";
      description = ''
        Second repository, on a DIFFERENT machine than tower and than the VPS. Copy
        best-effort: a powered-off machine does not make the backup fail.
        Empty string = no mirror.
      '';
    };
    mirrorVolume = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Also mirror the volume tier (775 MB); the Mac has only ~6 GB free.";
    };
    keepCoeur = lib.mkOption { type = lib.types.int; default = 30; description = "coeur archives kept on rack."; };
    keepVolume = lib.mkOption { type = lib.types.int; default = 3; description = "volume archives kept on rack."; };
    keepMortes = lib.mkOption { type = lib.types.int; default = 2; description = "mortes archives kept on rack."; };
    keepMirror = lib.mkOption { type = lib.types.int; default = 7; description = "Archives kept on the mirror."; };
    coeurAt = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 03:30:00";
      description = "Cadence of the coeur tier.";
    };
    volumeAt = lib.mkOption {
      type = lib.types.str;
      default = "Sun 04:30:00";
      description = "Cadence of the volume tier.";
    };
    pgRemoteHost = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        SSH host from which to pull the databases, dumped in streaming (`pg_dump` executed
        over there, sent by paramiko), instead of the local PostgreSQL. Used to make
        the expensive work (zstd -19) run on an idle machine while
        leaving the data on tower, whose `pg_hba` refuses everything that
        is not 127.0.0.1.
      '';
    };
    stateRemoteHost = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "SSH host from which to pull the Hermes state (`tar -c` streamed). Empty = local state.";
    };
    hermesRemoteDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes/.hermes";
      description = "Directory of the Hermes state on the remote host (the one that contains config.yaml, skills, sessions).";
    };
    skipIfFresh = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = ''
        Hours. If an archive of the same tier is younger than that, the run does
        nothing. This is what turns a host into a simple safety net
        behind the one that produces the archive normally.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services = {
      backup-pqbox-coeur = mkService "coeur" { startAt = cfg.coeurAt; };
      backup-pqbox-volume = mkService "volume" { startAt = cfg.volumeAt; };
      # The mortes tier stays manual: it serves once, before dropping the
      # abandoned databases. `systemctl start backup-pqbox-mortes` or
      # `pqbox backup mortes`.
      backup-pqbox-mortes = mkService "mortes" { };
    };
  };
}
