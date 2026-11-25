# services/finance-dashboard: spending tracking page (Wise + Chase).
#
# Chain: Pangolin (finance.marcpartensky.com, SSO) -> newt (tower site)
#          -> 127.0.0.1:9142 (this service).
# From the tailnet, the direct URL is http://100.64.0.3:9142 (no SSO).
#
# The service computes nothing: it renders /var/lib/hermes/workspace/finance/
# dashboard.json, written every morning by the "Daily finances recap" cron
# (/var/lib/hermes/.hermes/scripts/finance_recap.py, Wise + Chase via
# SimpleFIN). No secret is read here: the file is already aggregated.
#
# Why not Grafana: the figures fit in a 15 KB JSON
# regenerated once a day. A Grafana + Prometheus + exporter stack
# would cost two services and an agent for three daily series. A
# 400-line stdlib Python server does the same work, with the
# Catppuccin Mocha theme and the Lavender accent of the rest of the infra.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.financeDashboard;

  port = 9142;
  domain = "finance.marcpartensky.com";

  # Data produced by the Hermes cron (hermes user).
  dataDir = "/var/lib/hermes/workspace/finance";
  dataFile = "${dataDir}/dashboard.json";
in {
  options.services.financeDashboard = {
    enable = lib.mkEnableOption "spending tracking page (Wise + Chase)";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.finance-dashboard = {
      description = "Finance dashboard (Wise + Chase, read-only)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "simple";
        # Runs as hermes: it is this user that writes dashboard.json,
        # no shared group to maintain.
        User = "hermes";
        Group = "hermes";
        Environment = [
          "FINANCE_DASHBOARD_HOST=0.0.0.0"
          "FINANCE_DASHBOARD_PORT=${toString port}"
          "FINANCE_DASHBOARD_DATA=${dataFile}"
        ];
        ExecStart = "${pkgs.python3}/bin/python3 ${./finance_dashboard.py}";
        Restart = "always";
        RestartSec = 5;

        # Hardening: the service only reads a file and serves
        # cleartext HTTP behind newt.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
        ReadOnlyPaths = [dataDir];
      };
    };

    # The port stays closed at the firewall: access over the tailnet (trusted
    # interface) or via Pangolin SSO through newt, never cleartext from the LAN.
    services.newt.blueprint.proxy-resources.finance-dashboard = {
      name = "finance-dashboard";
      protocol = "http";
      full-domain = domain;
      auth.sso-enabled = true;
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
        message = "finance-dashboard: port ${toString port} must not be open at the firewall (tailnet access + Pangolin SSO only).";
      }
    ];
  };
}
