# services/ucpa-app : interface de recherche des sejours UCPA.
#
# Chaine : Pangolin (ucpa.marcpartensky.com, SSO) -> newt (site tower)
#          -> 127.0.0.1:9175 (ce service).
# Depuis le tailnet, l'URL directe est http://100.64.0.3:9175 (pas de SSO).
#
# Pourquoi une page maison : ucpa.com cache les prix derriere un selecteur de
# date, n'affiche que des minima de saison, ne filtre ni les formules (Mini /
# Mi-temps / Plein-temps) ni l'age, et melange les sessions avec et sans
# transport. Ici le catalogue est balaye une fois, toutes sessions datees avec
# prix et places, et le filtrage se fait dans le navigateur (aucun aller-retour).
#
# Aucune donnee propre : tout vient de l'API publique d'UCPA via le MEME
# client que le serveur MCP (mcp/modules/ucpa.py, importe par chemin). Un seul
# code parle a UCPA dans le depot, donc un seul endroit a corriger quand le
# site bouge.
#
# Le catalogue est mis en cache sur disque par fenetre de dates (3 h) et
# reconstruit en tache de fond : une requete ne reste jamais 70 s sur un
# balayage. Premier demarrage = une reconstruction immediate.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.ucpaApp;

  port = 9175;
  domain = "ucpa.marcpartensky.com";

  # Cache des catalogues (un fichier par fenetre de dates, ~200 Ko chacun).
  stateDir = "/var/lib/ucpa-app";

  clientModule = ../../mcp/modules/ucpa.py;
in {
  options.services.ucpaApp = {
    enable = lib.mkEnableOption "interface de recherche des sejours UCPA";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.ucpa-app = {
      description = "UCPA stay browser (ski/snowboard, prix par session)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "simple";
        # Tourne en hermes : il partage ainsi le cache disque du serveur MCP
        # (~/.local/state/ucpa-mcp/cache), donc un balayage sert aux deux.
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
        # Le premier balayage prend ~70 s ; on lui laisse de la marge.
        TimeoutStartSec = 120;

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = false; # le cache du client MCP vit dans ~hermes
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

    # Le port reste ferme au firewall : acces par le tailnet (interface de
    # confiance) ou par le SSO Pangolin via newt, jamais en clair depuis le LAN.
    services.newt.blueprint.proxy-resources.ucpa = {
      name = "ucpa";
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
        message = "ucpa-app : le port ${toString port} ne doit pas etre ouvert au firewall (acces tailnet + SSO Pangolin uniquement).";
      }
    ];
  };
}
