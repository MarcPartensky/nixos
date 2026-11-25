# services/presence : service de presence de marc, en Rust.
#
# Remplace l'ancien dashboard Python (systemd --user presence-dashboard, qui
# brulait ~40 % d'un coeur en scannant /proc et journalctl toutes les 5 s).
# Le service Rust fait le meme travail pour ~0,1 % de CPU : un thread de tick
# qui lit quelques fichiers, deux threads de sondes SSH qui dorment, un serveur
# tokio mono-thread qui renvoie un JSON deja serialise.
#
# Ce qu'il produit, et qui reste le CONTRAT avec le reste du systeme :
#   - /var/lib/hermes/presence-dashboard/devices.json : etat de chaque
#     appareil (lu par taskq/presence.py et le dispatcher de la file) ;
#   - /var/lib/hermes/presence-dashboard/forecast.json : prevision + drapeau
#     `reserve` (lu par le gouverneur CPU, services/cpu-priority) ;
#   - /var/lib/hermes/presence-dashboard/activity.jsonl : une ligne par minute
#     (presence, lieu, CPU des taches de fond) pour apprendre les habitudes ;
#   - HTTP 9143 : /, /api/state, /api/forecast, /api/history, /healthz.
#
# Les sondes ont besoin de ssh (Mac, telephone via le rack), ss (KasmVNC),
# tailscale (position du telephone) et sqlite3 (state.db de Hermes). Le PATH du
# service les fournit explicitement : rien n'est herite du profil interactif.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.presence;

  rust = pkgs.callPackage ./package.nix {};
in {
  options.services.presence = {
    enable = lib.mkEnableOption "service de presence (Rust) pour marc";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9143;
      description = "Port HTTP du service (loopback + tailnet, jamais ouvert au firewall).";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes/presence-dashboard";
      description = ''
        Dossier d'etat. Conserve le chemin historique : la file taskq lit
        devices.json ici, la migration ne doit rien casser.
      '';
    };

    macHost = lib.mkOption {
      type = lib.types.str;
      default = "maclan";
      description = "Hote SSH du Mac quand il est sur le LAN (sinon repli `mac` via le rack).";
    };

    homeGatewayMac = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["74:37:5f:a1:dd:70"];
      description = ''
        MAC de la passerelle du reseau maison. Le Mac derriere cette passerelle
        est a la maison ; derriere une autre, il est dehors (ou au bureau, si
        l'adresse a ete apprise comme telle).
      '';
    };

    reserveP = lib.mkOption {
      type = lib.types.float;
      default = 0.45;
      description = ''
        Seuil de probabilite au-dela duquel la machine est RESERVEE pour marc
        dans les 30 prochaines minutes : les jobs de fond restent brides.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.presence = {
      description = "Presence de marc (Rust) : appareils, lieu, prevision, reservation CPU";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target" "postgresql.service" "postgresql-setup.service"];
      wants = ["network-online.target"];
      # la base est creee par postgresql-setup (ensureDatabases)
      requires = ["postgresql-setup.service"];

      path = with pkgs; [openssh iproute2 tailscale sqlite postgresql];
      environment = {
        TZ = "America/New_York";
        PRESENCE_HOST = "0.0.0.0";
        PRESENCE_PORT = toString cfg.port;
        PRESENCE_STATE_DIR = cfg.stateDir;
        HERMES_HOME = "/var/lib/hermes";
        PRESENCE_MAC_HOST = cfg.macHost;
        PRESENCE_MAC_FALLBACK = "mac";
        PRESENCE_PHONE_HOST = "phone";
        PRESENCE_PHONE_TS = "Xiaomi 13T Pro";
        PRESENCE_HOME_GW = lib.concatStringsSep "," cfg.homeGatewayMac;
        PRESENCE_RESERVE_P = toString cfg.reserveP;
        # sondes : Mac 8 s en ligne / 60 s hors ligne, telephone 3 min
        PRESENCE_MAC_EVERY = "8";
        PRESENCE_MAC_EVERY_OFFLINE = "60";
        PRESENCE_PHONE_EVERY = "180";
        PRESENCE_NET_EVERY = "60";
        TASKQ_PRESENCE_CONFIG = "/etc/taskq/presence.json";
        # journal de presence : une ligne par minute dans Postgres (base dediee,
        # role `presence`, trust loopback). Les fichiers restent ecrits pour le
        # gouverneur CPU et la file taskq (petits contrats, pas des journaux).
        PRESENCE_PG = "postgresql://presence@127.0.0.1:5432/presence";
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${rust}/bin/presence";
        User = "hermes";
        Group = "hermes";
        Restart = "always";
        RestartSec = 3;
        # un service de veille : il ne doit jamais peser
        Nice = 10;
        CPUQuota = "20%";
        MemoryMax = "192M";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = "read-only";
        ProtectSystem = "full";
        ReadWritePaths = [cfg.stateDir];
        # ssh vers le Mac et le telephone : cle de l'utilisateur hermes
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
      };
    };

    # Base dediee : le journal de presence est une serie temporelle qu'on
    # interroge (24 h, semaine type, CPU pendant que marc est la), donc
    # Postgres plutot qu'un JSONL qu'il faudrait relire en entier.
    services.postgresql.ensureDatabases = ["presence"];
    services.postgresql.ensureUsers = [
      {
        name = "presence";
        ensureDBOwnership = true;
      }
    ];
    services.postgresqlBackup.databases = lib.mkAfter ["presence"];

    systemd.services.presence-schema = {
      description = "Applique le schema SQL du service presence";
      wantedBy = ["multi-user.target"];
      after = ["postgresql.service" "postgresql-setup.service"];
      requires = ["postgresql.service" "postgresql-setup.service"];
      serviceConfig = {
        Type = "oneshot";
        # `presence` est un ROLE Postgres, pas un compte systeme : psql tourne
        # en postgres (peer) et la base est en trust sur la loopback.
        User = "postgres";
        RemainAfterExit = true;
      };
      script = ''
        ${config.services.postgresql.package}/bin/psql -h 127.0.0.1 -U presence -d presence \
          -v ON_ERROR_STOP=1 -q -f ${./schema.sql}
      '';
    };

    # Le port reste ferme au firewall : tailnet, ou Pangolin via newt.
    assertions = [
      {
        assertion = !(lib.elem cfg.port config.networking.firewall.allowedTCPPorts);
        message = "presence : le port ${toString cfg.port} ne doit pas etre ouvert au firewall.";
      }
    ];
  };
}
