# services/presence: marc's presence service, in Rust.
#
# Replaces the old Python dashboard (systemd --user presence-dashboard, which
# burned ~40% of a core scanning /proc and journalctl every 5 s).
# The Rust service does the same job for ~0.1% CPU: a tick thread
# that reads a few files, two sleeping SSH probe threads, a single-threaded
# tokio server that returns an already serialized JSON.
#
# What it produces, and which remains the CONTRACT with the rest of the system:
#   - /var/lib/hermes/presence-dashboard/devices.json: state of each
#     device (read by taskq/presence.py and the queue dispatcher);
#   - /var/lib/hermes/presence-dashboard/forecast.json: forecast + flag
#     `reserve` (read by the CPU governor, services/cpu-priority);
#   - /var/lib/hermes/presence-dashboard/activity.jsonl: one line per minute
#     (presence, location, background task CPU) to learn the habits;
#   - HTTP 9143: /, /api/state, /api/forecast, /api/history, /healthz.
#
# The probes need ssh (Mac, phone via the rack), ss (KasmVNC),
# tailscale (phone location) and sqlite3 (Hermes state.db). The service's
# PATH provides them explicitly: nothing is inherited from the interactive profile.
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
    enable = lib.mkEnableOption "presence service (Rust) for marc";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9143;
      description = "HTTP port of the service (loopback + tailnet, never opened in the firewall).";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes/presence-dashboard";
      description = ''
        State directory. Keeps the historical path: the taskq queue reads
        devices.json here, the migration must not break anything.
      '';
    };

    macHost = lib.mkOption {
      type = lib.types.str;
      default = "maclan";
      description = "SSH host of the Mac when it is on the LAN (otherwise fallback `mac` via the rack).";
    };

    homeGatewayMac = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["74:37:5f:a1:dd:70"];
      description = ''
        MAC of the home network gateway. The Mac behind this gateway
        is at home; behind another, it is outside (or at the office, if
        the address was learned as such.
      '';
    };

    reserveP = lib.mkOption {
      type = lib.types.float;
      default = 0.45;
      description = ''
        Probability threshold beyond which the machine is RESERVED for marc
        in the next 30 minutes: background jobs stay throttled.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.presence = {
      description = "Presence of marc (Rust): devices, location, forecast, CPU reservation";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target" "postgresql.service" "postgresql-setup.service"];
      wants = ["network-online.target"];
      # the database is created by postgresql-setup (ensureDatabases)
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
        # probes: Mac 8 s online / 60 s offline, phone 3 min
        PRESENCE_MAC_EVERY = "8";
        PRESENCE_MAC_EVERY_OFFLINE = "60";
        PRESENCE_PHONE_EVERY = "180";
        PRESENCE_NET_EVERY = "60";
        TASKQ_PRESENCE_CONFIG = "/etc/taskq/presence.json";
        # presence journal: one line per minute in Postgres (dedicated database,
        # role `presence`, trust loopback). The files remain written for the
        # CPU governor and the taskq queue (small contracts, not journals).
        PRESENCE_PG = "postgresql://presence@127.0.0.1:5432/presence";
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${rust}/bin/presence";
        User = "hermes";
        Group = "hermes";
        Restart = "always";
        RestartSec = 3;
        # a background service: it must never be heavy
        Nice = 10;
        CPUQuota = "20%";
        MemoryMax = "192M";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = "read-only";
        ProtectSystem = "full";
        ReadWritePaths = [cfg.stateDir];
        # ssh to the Mac and the phone: hermes user's key
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
      };
    };

    # Dedicated database: the presence journal is a time series that
    # is queried (24 h, typical week, CPU while marc is there), so
    # Postgres rather than a JSONL that would have to be re-read entirely.
    services.postgresql.ensureDatabases = ["presence"];
    services.postgresql.ensureUsers = [
      {
        name = "presence";
        ensureDBOwnership = true;
      }
    ];
    services.postgresqlBackup.databases = lib.mkAfter ["presence"];

    systemd.services.presence-schema = {
      description = "Applies the SQL schema of the presence service";
      wantedBy = ["multi-user.target"];
      after = ["postgresql.service" "postgresql-setup.service"];
      requires = ["postgresql.service" "postgresql-setup.service"];
      serviceConfig = {
        Type = "oneshot";
        # `presence` is a Postgres ROLE, not a system account: psql runs
        # as postgres (peer) and the database is in trust on the loopback.
        User = "postgres";
        RemainAfterExit = true;
      };
      script = ''
        ${config.services.postgresql.package}/bin/psql -h 127.0.0.1 -U presence -d presence \
          -v ON_ERROR_STOP=1 -q -f ${./schema.sql}
      '';
    };

    # The port stays closed in the firewall: tailnet, or Pangolin via newt.
    assertions = [
      {
        assertion = !(lib.elem cfg.port config.networking.firewall.allowedTCPPorts);
        message = "presence: port ${toString cfg.port} must not be open in the firewall.";
      }
    ];
  };
}
