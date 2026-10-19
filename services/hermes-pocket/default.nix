# services/hermes-pocket/default.nix
# Backend de l'appli mobile Hermes Pocket : `hermes serve --isolated` sur le
# profil « pocket », instance séparée du gateway Matrix (hermes-agent) et du
# dashboard web (hermes-dashboard).
#
# Chaîne : Pangolin (hermes-mobile.marcpartensky.com, SSO DÉSACTIVÉ)
#          -> newt (site tower)
#          -> 127.0.0.1:9129 (nginx, réécrit Host: 127.0.0.1:9119)
#          -> 127.0.0.1:9119 (hermes serve --isolated, profil pocket).
#
# Depuis le 19/10/2026, la porte d'auth native du serve est ACTIVE : serve.env
# déclare dashboard.public_url (HERMES_DASHBOARD_PUBLIC_URL), ce qui engage
# auth_required=true même sur un bind loopback (doctrine upstream : derrière
# un proxy, le token de session local ne doit jamais être servi sans auth).
# Sans cette porte, le serve headless servait la page racine avec
# window.__HERMES_SESSION_TOKEN__ en clair ; publiée par Pangolin (SSO
# désactivé), elle exposait le token de session au monde entier. Fuite fermée
# et token rotaté le 19/10/2026.
#
# Flux client (appli « Hermes Mobile » F-Droid, mode Username & Password) :
# POST /auth/password-login (provider basic, identifiants dans serve.env)
# -> cookies de session -> POST /api/auth/ws-ticket
# -> ws(s)://<domaine>/api/ws?ticket=<billet> (usage unique, TTL 30 s).
#
# Notes de la période NON gardée (27/09/2026) : le token n'était accepté qu'en
# paramètre de requête (Bearer refusé), et le serveur refuse tout Host non
# loopback (anti DNS-rebinding), d'où la réécriture Host par nginx comme dans
# hermes-webui et hermes-dashboard.
# Ne jamais ouvrir 9119 ou 9129 au firewall : le serveur expose l'API complète
# de l'agent (outils, fichiers, terminal) ; la porte d'auth protège l'accès.
{
  config,
  lib,
  ...
}: let
  profileDir = "/var/lib/hermes/.hermes/profiles/pocket";
  backendPort = 9119;
  proxyPort = 9129;
  backendUrl = "http://127.0.0.1:${toString backendPort}";
  backendHost = "127.0.0.1:${toString backendPort}";
in {
  systemd.services.hermes-pocket-serve = {
    description = "Hermes serve (profil pocket) : backend de l'appli mobile Hermes Pocket";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      User = config.services.hermes-agent.user;
      Group = config.services.hermes-agent.group;

      # même cwd que la session d'origine de l'appli (cf. README du projet)
      WorkingDirectory = "/var/lib/hermes/workspace";

      # HERMES_HOME pointe sur le profil, et --isolated empêche le rattachement
      # au serveur unifié de la machine (qui est celui du dashboard).
      Environment = [
        "HERMES_HOME=${profileDir}"
        "HERMES_REAL_HOME=/var/lib/hermes"
      ];

      # .env = clés de provider du profil ; serve.env = réglages de la porte
      # d'auth (HERMES_DASHBOARD_PUBLIC_URL, HERMES_DASHBOARD_BASIC_AUTH_*) et
      # token de session legacy — les deux hors du store nix.
      EnvironmentFile = [
        "${profileDir}/.env"
        "${profileDir}/serve.env"
      ];

      ExecStart = "${config.services.hermes-agent.package}/bin/hermes serve --isolated --port ${toString backendPort} --host 127.0.0.1";

      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Proxy local : seul point d'entrée loopback ; il réécrit le Host que le
  # serveur impose, laisse passer l'Upgrade WebSocket, et annonce au backend
  # https + l'IP cliente réelle (cookies Secure, audit) via X-Forwarded-*.
  services.nginx.virtualHosts."hermes-pocket-proxy" = {
    listen = [
      {
        addr = "127.0.0.1";
        port = proxyPort;
      }
    ];
    locations."/" = {
      proxyPass = backendUrl;
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host ${backendHost};
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
      '';
    };
  };

  # Ressource publique Pangolin, appliquée par le site qui porte le blueprint
  # (donc tower) : `site` est omis volontairement, cf. services/newt.
  # Pas de bloc `auth` : c'est le seul moyen de laisser l'appli native se
  # connecter (SSO navigateur impossible), exactement comme la ressource
  # jellyfin. La cible reste loopback, seul nginx est publié.
  services.newt.blueprint.proxy-resources.hermes-pocket = {
    name = "hermes-pocket";
    protocol = "http";
    full-domain = "hermes-mobile.marcpartensky.com";
    targets = [
      {
        hostname = "127.0.0.1";
        port = proxyPort;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = proxyPort;
          # La racine gardée redirige vers /login (302) ; /api/status est la
          # sonde publique (200) tant que la porte est active.
          path = "/api/status";
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

  # Garde-fou : ces ports ne doivent jamais être ouverts sur le LAN.
  assertions = [
    {
      assertion = !(lib.elem backendPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-pocket : le port ${toString backendPort} (API agent complète, protégée par un simple token) ne doit pas être ouvert au firewall.";
    }
    {
      assertion = !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-pocket : le port ${toString proxyPort} (proxy du backend) ne doit pas être ouvert au firewall.";
    }
  ];
}
