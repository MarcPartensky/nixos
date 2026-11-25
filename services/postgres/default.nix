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
    # pgvector : vector store pour la mémoire mem0 de hermes
    # même majeur (17.11) -> simple restart, pas de dump/restore
    package = pkgs.postgresql_17.withPackages (ps: [ ps.pgvector ]);
    settings = {
      ssl_cert_file = config.sops.secrets."postgres_crt".path;
      ssl_key_file  = config.sops.secrets."postgres_key".path;
      # Le defaut de 100 a ete ATTEINT le 14/11/2026 a 02h10 (103 connexions) :
      # winnie-ingest ouvre jusqu'a 55 connexions courtes en pointe et le role
      # windmill s'est vu refuser la sienne ("remaining connection slots are
      # reserved for roles with the SUPERUSER attribute"). Toute pool qui ne
      # peut plus ouvrir de connexion attend son timeout, ce qui se traduit
      # cote client par des requetes qui pendent puis echouent : c'est le
      # mecanisme le plus credible des gels du backend Hermes. 300 laisse de la
      # marge pour toutes les bases (une trentaine d'instances) sans pression
      # memoire notable sur 62 Go.
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


    # Authentification (locale et localhost)
    authentication = pkgs.lib.mkOverride 10 ''
      # type database  DBuser  auth-method
      local all all trust

      # IPv4 localhost
      host all all 127.0.0.1/32 trust

      # IPv6 localhost
      host all all ::1/128 trust

      # Workers Windmill (deck, anywhere) : uniquement le role `windmill` sur
      # la base `windmill`, uniquement depuis le tailnet headscale, et avec le
      # mot de passe scram (sops). Sans cette ligne, le worker echoue en
      # "no pg_hba.conf entry for host 100.64.x.x" et reste en CrashLoop.
      host windmill windmill 100.64.0.0/10 scram-sha-256
    '';

    # # Script SQL initial pour créer utilisateurs et droits
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

  # Recovery WAL = demarrage long. Le 17/11/2026 tower a redemarre sans arret
  # propre ; postgres a rejoue son WAL pendant plus de 120 s, systemd l'a tue au
  # TimeoutStartSec par defaut, et TOUT ce qui en depend est tombe en
  # « dependency failed » sans jamais etre relance : matrice 503 pendant 5 h,
  # immich et attic avec. 15 min couvrent une recovery large sur ce disque ZFS
  # sans masquer un vrai blocage (postgres logue sa progression).
  systemd.services.postgresql.serviceConfig.TimeoutStartSec = "15min";
}

