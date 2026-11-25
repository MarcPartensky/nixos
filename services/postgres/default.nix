{ pkgs, config, ... }:

{
  imports = [ ./music.nix ];

  sops.secrets."postgres_crt" = {
    sopsFile = ../../secrets/common.yml;
    owner    = "postgres";
    path     = "/var/lib/postgresql/server.crt";
  };
  sops.secrets."postgres_key" = {
    sopsFile = ../../secrets/common.yml;
    owner    = "postgres";
    mode     = "0600";
    path     = "/var/lib/postgresql/server.key";
  };
  
  services.postgresql = {
    enable = true;
    # pgvector: vector store for hermes's mem0 memory
    # same major (17.11) -> simple restart, no dump/restore
    package = pkgs.postgresql_17.withPackages (ps: [ ps.pgvector ]);
    settings = {
      ssl_cert_file = config.sops.secrets."postgres_crt".path;
      ssl_key_file  = config.sops.secrets."postgres_key".path;
      # The default of 100 was REACHED on 14/11/2026 at 02h10 (103 connections):
      # winnie-ingest opens up to 55 short connections at peak and the
      # windmill role was denied its own ("remaining connection slots are
      # reserved for roles with the SUPERUSER attribute"). Any pool that can no
      # longer open a connection waits for its timeout, which translates
      # on the client side into requests that hang then fail: this is the
      # most credible mechanism of the Hermes backend freezes. 300 leaves
      # room for all the databases (about thirty instances) without notable
      # memory pressure on 62 GB.
      max_connections = 300;
    };


    # ensureDatabases = [ "vaultwarden" ];

    ensureUsers = [
      {
        name = "root";
        ensureClauses = { superuser = true; login = true; };
        # Password setting via Nix is complex, usually handled manually or via socket auth
      }
    ];


    # Authentication (local and localhost)
    authentication = pkgs.lib.mkOverride 10 ''
      # type database  DBuser  auth-method
      local all all trust

      # IPv4 localhost
      host all all 127.0.0.1/32 trust

      # IPv6 localhost
      host all all ::1/128 trust

      # Windmill workers (deck, anywhere): only the `windmill` role on
      # the `windmill` database, only from the headscale tailnet, and with the
      # scram password (sops). Without this line, the worker fails with
      # "no pg_hba.conf entry for host 100.64.x.x" and stays in CrashLoop.
      host windmill windmill 100.64.0.0/10 scram-sha-256
    '';

    # # Initial SQL script to create users and rights
    # initialScript = pkgs.writeText "init.sql" ''
    #   CREATE USER root WITH LOGIN PASSWORD 'rootpassword' SUPERUSER;
    #
    #   -- Nextcloud
    #   CREATE USER nextcloud WITH LOGIN PASSWORD 'nextcloudpassword';
    #   GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
  };

  services.postgresqlBackup = {
    enable = true;
    location = "/root/backup/nextcloud";
    databases = [ "nextcloud" ];
    # time to start backup in systemd.time format
    startAt = "*-*-* 5:00:00";
  };

  # WAL recovery = long start. On 17/11/2026 tower restarted without a clean
  # shutdown; postgres replayed its WAL for more than 120 s, systemd killed it at
  # the default TimeoutStartSec, and EVERYTHING depending on it fell into
  # "dependency failed" without ever being restarted: matrix 503 for 5 h,
  # immich and attic with it. 15 min covers a large recovery on this ZFS disk
  # without masking a real hang (postgres logs its progress).
  systemd.services.postgresql.serviceConfig.TimeoutStartSec = "15min";
}

