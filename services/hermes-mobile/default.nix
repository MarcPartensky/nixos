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
  pkgs,
  ...
}: let
  # Page « Hermes vocal » : client web duplex (VAD + barge-in) servi par le même
  # domaine que l'appli mobile, donc same-origin avec la porte d'auth (cookies)
  # et le WebSocket. Cf. voice.html.
  voicePage = pkgs.runCommandLocal "hermes-voice-page" {} ''
    mkdir -p $out
    cp ${./voice.html} $out/voice.html
  '';

  # Service de réglages de voix (moteur, voix, vitesse, hauteur) + synthèse des
  # aperçus, proxifié sous /voice/api/ (même origine que la page, donc cookies).
  voiceSettingsPort = 9134;
  voiceSettingsState = "/var/lib/hermes/.hermes/voice-settings.json";
  # Interpréteur = venv scellé de Hermes (edge-tts 7.3.x y est). Le edge-tts de
  # nixpkgs (7.2.8) se fait refuser par le service Microsoft : 403 « Invalid
  # response status » sur le websocket, donc la version compte.
  voiceSettingsPython = "${config.services.hermes-agent.package.hermesVenv}/bin/python3";
  voiceSettingsScript = pkgs.writeText "hermes-voice-settings.py"
    (builtins.readFile ./voice-settings.py);

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
    # Un rebuild NixOS ne doit pas couper ce serveur : les sessions mobiles
    # vivent dedans. La nouvelle config s'applique au prochain demarrage.
    restartIfChanged = false;
    description = "Hermes serve (profil default) : backend de l'appli mobile Hermes Mobile";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      User = config.services.hermes-agent.user;
      Group = config.services.hermes-agent.group;

      # Même traitement que hermes-agent et hermes-backend : sans cette ligne
      # l'unité vit dans system.slice au poids 100, sur les 16 threads, à
      # égalité avec le bureau de marc. Mesuré le 12/11/2026 : 37 % d'un cœur
      # en continu avec une session ouverte à 2 messages, pendant que la
      # machine était en swap plein. hermes.slice la confine aux threads
      # réservés (12-13, poids 2000) comme le reste de la pile Hermes.
      Slice = "hermes.slice";

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

  # Réglages de voix : même utilisateur que le backend, état dans le home Hermes.
  systemd.services.hermes-voice-settings = {
    description = "Hermes vocal : réglages de voix et synthèse des aperçus";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      User = config.services.hermes-agent.user;
      Group = config.services.hermes-agent.group;
      WorkingDirectory = "/var/lib/hermes/workspace";
      Environment = [
        "HOME=/var/lib/hermes"
        "VOICE_SETTINGS_PORT=${toString voiceSettingsPort}"
        "VOICE_SETTINGS_STATE=${voiceSettingsState}"
      ];
      ExecStart = "${voiceSettingsPython} ${voiceSettingsScript}";
      Restart = "always";
      RestartSec = 5;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = false;
      ReadWritePaths = ["/var/lib/hermes/.hermes"];
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

    # Client vocal web (same-origin : cookies de la porte d'auth + /api/ws).
    # La page elle-même ne contient aucun secret : la connexion se fait par le
    # formulaire, puis toutes les requêtes /api/* repassent par le proxy ci-dessus.
    locations."= /voice" = {
      alias = "${voicePage}/voice.html";
      extraConfig = "default_type text/html; add_header Cache-Control \"no-store\";";
    };
    locations."= /voice/" = {
      return = "302 /voice";
    };

    # API des réglages de voix (état, catalogue, aperçus, synthèse). Préfixe
    # plus spécifique que "/" : il gagne sur le proxy du backend.
    locations."/voice/api/" = {
      proxyPass = "http://127.0.0.1:${toString voiceSettingsPort}/";
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        client_max_body_size 1m;
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
