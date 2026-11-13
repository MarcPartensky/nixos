# services/finance-dashboard : page de suivi des dépenses (Wise + Chase).
#
# Chaine : Pangolin (finance.marcpartensky.com, SSO) -> newt (site tower)
#          -> 127.0.0.1:9142 (ce service).
# Depuis le tailnet, l'URL directe est http://100.64.0.3:9142 (pas de SSO).
#
# Le service ne calcule rien : il rend /var/lib/hermes/workspace/finance/
# dashboard.json, ecrit chaque matin par le cron « Daily finances recap »
# (/var/lib/hermes/.hermes/scripts/finance_recap.py, Wise + Chase via
# SimpleFIN). Aucun secret n'est lu ici : le fichier est deja agrege.
#
# Pourquoi pas Grafana : les chiffres tiennent dans un JSON de 15 Ko
# regenere une fois par jour. Une pile Grafana + Prometheus + exposition
# couterait deux services et un agent pour trois series quotidiennes. Un
# serveur Python stdlib de 400 lignes fait le meme travail, avec le theme
# Catppuccin Mocha et l'accent Lavender du reste de l'infra.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.financeDashboard;

  port = 9142;
  domain = "finance.marcpartensky.com";

  # Donnees produites par le cron Hermes (utilisateur hermes).
  dataDir = "/var/lib/hermes/workspace/finance";
  dataFile = "${dataDir}/dashboard.json";
in {
  options.services.financeDashboard = {
    enable = lib.mkEnableOption "page de suivi des depenses (Wise + Chase)";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.finance-dashboard = {
      description = "Finance dashboard (Wise + Chase, lecture seule)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "simple";
        # Tourne en hermes : c'est cet utilisateur qui ecrit dashboard.json,
        # pas de groupe partage a maintenir.
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

        # Durcissement : le service ne fait que lire un fichier et servir du
        # HTTP en clair derriere newt.
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

    # Le port reste ferme au firewall : acces par le tailnet (interface de
    # confiance) ou par le SSO Pangolin via newt, jamais en clair depuis le LAN.
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
        message = "finance-dashboard : le port ${toString port} ne doit pas etre ouvert au firewall (acces tailnet + SSO Pangolin uniquement).";
      }
    ];
  };
}
