# services/hermes-mobile/default.nix
# Backend de l'appli mobile « Hermes Mobile » (F-Droid, com.m57.hermescontrol) :
# `hermes serve --isolated` sur le profil DEFAULT de tower, donc le MÊME agent
# que le gateway Matrix (hermes-agent), le dashboard (hermes-dashboard) et les
# sessions du desktop. Ce module remplace l'ancien backend sur le profil isolé
# « pocket » (services/hermes-pocket) : l'appli mobile voit désormais
# l'historique, la mémoire, les skills et le modèle du profil default au lieu
# d'un profil séparé.
#
# Chaîne : Pangolin (hermes-mobile.marcpartensky.com, SSO DÉSACTIVÉ)
#          -> newt (site tower)
#          -> 127.0.0.1:9129 (nginx, réécrit Host: 127.0.0.1:9119)
#          -> 127.0.0.1:9119 (hermes serve --isolated, HERMES_HOME default).
#
# Pourquoi --isolated : le serveur « unifié » de la machine est déjà celui du
# dashboard (127.0.0.1:9120). Sans --isolated, `hermes serve` refuse de démarrer
# (exit 78, « this host is already served by PID … »). --isolated crée un backend
# dédié, comme le fait Hermes Desktop pour ses connexions SSH. Plusieurs backends
# sur le même state.db sont normaux : c'est déjà le cas du gateway, du dashboard
# et des backends SSH du desktop.
#
# Porte d'auth native ACTIVE : mobile-serve.env (0600, hors store nix) déclare
# HERMES_DASHBOARD_PUBLIC_URL=https://hermes-mobile.marcpartensky.com +
# HERMES_DASHBOARD_BASIC_AUTH_* ; un public_url non-loopback engage
# auth_required=true même sur un bind loopback (doctrine upstream). Sans cette
# porte, le serve headless servirait la page racine avec
# window.__HERMES_SESSION_TOKEN__ en clair derrière une ressource Pangolin sans
# SSO : fuite du token de session (incident du 19/10/2026, cf. historique pocket).
#
# Flux client (appli « Hermes Mobile » F-Droid, mode Username & Password) :
# POST /auth/password-login (provider basic, identifiants dans mobile-serve.env)
# -> cookies de session -> POST /api/auth/ws-ticket
# -> ws(s)://<domaine>/api/ws?ticket=<billet> (usage unique, TTL 30 s).
#
# Ne jamais ouvrir 9119 ou 9129 au firewall : le serveur expose l'API complète
# de l'agent (outils, fichiers, terminal) ; la porte d'auth protège l'accès.
{
  config,
  lib,
  ...
}: let
  # Profil default : /var/lib/hermes/.hermes (config Nix-managed, marqueur
  # .managed écrit par l'activation NixOS, donc les écritures de config depuis
  # l'appli sont refusées comme depuis le dashboard).
  profileDir = "/var/lib/hermes/.hermes";
  backendPort = 9119;
  proxyPort = 9129;
  backendUrl = "http://127.0.0.1:${toString backendPort}";
  backendHost = "127.0.0.1:${toString backendPort}";
in {
  systemd.services.hermes-mobile-serve = {
    description = "Hermes serve (profil default) : backend de l'appli mobile Hermes Mobile";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      User = config.services.hermes-agent.user;
      Group = config.services.hermes-agent.group;

      # même cwd que la session d'origine de l'appli (cf. README du projet)
      WorkingDirectory = "/var/lib/hermes/workspace";

      # HERMES_HOME = profil default, et --isolated pour ne pas entrer en
      # conflit avec le backend machine du dashboard.
      Environment = [
        "HERMES_HOME=${profileDir}"
        "HERMES_REAL_HOME=/var/lib/hermes"
      ];

      # .env = clés de provider du profil default ; mobile-serve.env = réglages
      # de la porte d'auth (public_url, basic auth). Les deux hors du store nix.
      EnvironmentFile = [
        "${profileDir}/.env"
        "${profileDir}/mobile-serve.env"
      ];

      ExecStart = "${config.services.hermes-agent.package}/bin/hermes serve --isolated --port ${toString backendPort} --host 127.0.0.1";

      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Proxy local : seul point d'entrée loopback ; il réécrit le Host que le
  # serveur impose, laisse passer l'Upgrade WebSocket, et annonce au backend
  # https + l'IP cliente réelle (cookies Secure, audit) via X-Forwarded-*.
  services.nginx.virtualHosts."hermes-mobile-proxy" = {
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
  # Le nom de ressource « hermes-pocket » est conservé volontairement : c'est
  # l'identité existante côté Pangolin pour ce domaine, la renommer ferait
  # créer une seconde ressource sur un domaine déjà pris. Seul le backend
  # derrière a changé (profil default).
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
      message = "hermes-mobile : le port ${toString backendPort} (API agent complète, protégée par une porte d'auth) ne doit pas être ouvert au firewall.";
    }
    {
      assertion = !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-mobile : le port ${toString proxyPort} (proxy du backend) ne doit pas être ouvert au firewall.";
    }
  ];
}
