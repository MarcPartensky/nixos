# services/ucpa-app: UCPA stays search interface.
#
# Chain: Pangolin (ucpa.marcpartensky.com, public, no SSO) -> newt (site tower)
#          -> 127.0.0.1:9175 (this service).
# From the tailnet, the direct URL is http://100.64.0.3:9175 (no SSO).
#
# Why a home-made page: ucpa.com hides prices behind a date
# selector, only shows season minima, does not filter either the formulas (Mini /
# Half-time / Full-time) nor the age, and mixes sessions with and without
# transport. Here the catalog is swept once, all sessions dated with
# price and seats, and filtering happens in the browser (no round-trip).
#
# No data of its own: everything comes from UCPA's public API via the SAME
# client as the MCP server (mcp/modules/ucpa.py, imported by path). A single
# piece of code talks to UCPA in the repo, so a single place to fix when the
# site moves.
#
# The catalog is cached on disk per date window (3 h) and
# rebuilt in the background: a request never stays 70 s on a
# sweep. First startup = an immediate rebuild.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.ucpaApp;

  port = 9175;
  domain = "ucpa.marcpartensky.com";

  # Catalog cache (one file per date window, ~200 kB each).
  stateDir = "/var/lib/ucpa-app";

  clientModule = ../../mcp/modules/ucpa.py;
in {
  options.services.ucpaApp = {
    enable = lib.mkEnableOption "UCPA stays search interface";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.ucpa-app = {
      description = "UCPA stay browser (ski/snowboard, price per session)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "simple";
        # Runs as hermes: it thus shares the MCP server's disk cache
        # (~/.local/state/ucpa-mcp/cache), so one sweep serves both.
        User = "hermes";
        Group = "hermes";
        Environment = [
          "UCPA_APP_HOST=127.0.0.1"
          "UCPA_APP_PORT=${toString port}"
          "UCPA_APP_STATE=${stateDir}"
          "UCPA_APP_INDEX=${./index.html}"
          "UCPA_MODULE=${clientModule}"
        ];
        ExecStart = "${pkgs.python3}/bin/python3 ${./server.py}";
        Restart = "always";
        RestartSec = 5;
        # The first sweep takes ~70 s; we give it some margin.
        TimeoutStartSec = 120;

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false; # the MCP client cache lives in ~hermes
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
        ReadWritePaths = [stateDir];
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 hermes hermes -"
    ];

    # The port stays closed in the firewall: access via the tailnet (trusted
    # interface) or via Pangolin/newt, never in clear from the LAN.
    services.newt.blueprint.proxy-resources.ucpa = {
      name = "ucpa";
      protocol = "http";
      full-domain = domain;
      # Deliberately public: the page only shows UCPA's public catalog and
      # prices, and it has no auth of its own. Setting sso-enabled back to true
      # puts the domain behind the Pangolin dashboard again.
      auth.sso-enabled = false;
      targets = [
        {
          hostname = "127.0.0.1";
          port = port;
          method = "http";
          healthcheck = {
            enabled = true;
            hostname = "127.0.0.1";
            port = port;
            path = "/healthz";
            scheme = "http";
            mode = "http";
            method = "GET";
            interval = 30;
            unhealthy-interval = 30;
            timeout = 5;
            healthy-threshold = 1;
            unhealthy-threshold = 3;
          };
        }
      ];
    };

    assertions = [
      {
        assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
        message = "ucpa-app: port ${toString port} must not be open in the firewall (tailnet access + Pangolin only).";
      }
    ];
  };
}
