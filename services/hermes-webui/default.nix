# services/hermes-webui/default.nix
# UI web de chat Hermes (projet communautaire github:nesquena/hermes-webui,
# input flake) tournant sur le profil « pocket », isolé du gateway Matrix.
#
# Chaîne : Pangolin (webui.marcpartensky.com, SSO)
#          -> newt (site tower)
#          -> 127.0.0.1:9131 (nginx, réécrit Host: 127.0.0.1:9130)
#          -> 127.0.0.1:9130 (services.hermes-webui).
#
# Le serveur tourne l'agent EN PROCESS (pas de gateway API) : il lit donc le
# HERMES_HOME qu'on lui donne. Deux pièges vérifiés le 25/09/2026 :
#  1. HERMES_HOME seul ne suffit PAS : sans HERMES_WEBUI_ISOLATED_PROFILE=1 le
#     serveur retombe sur le profil par défaut et écrit dans le state.db
#     racine (/var/lib/hermes/.hermes/state.db), partagé avec le gateway
#     Matrix et les sessions CLI. Avec le flag, le profil actif devient bien
#     pocket et seule sa propre base est touchée.
#  2. Il n'y a PAS de garde d'authentification sur une adresse loopback (elle
#     ne s'active que sur une adresse non-loopback). C'est le SSO Pangolin qui
#     protège l'accès, exactement comme terminal.marcpartensky.com. Ne jamais
#     ouvrir 9130/9131 au firewall : le serveur expose aussi un PTY (/api/pty)
#     et l'API complète (sessions, mémoire, fichiers) sans mot de passe.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  profileDir = "/var/lib/hermes/.hermes/profiles/pocket";
  backendPort = 9130;
  proxyPort = 9131;
  backendUrl = "http://127.0.0.1:${toString backendPort}";
  backendHost = "127.0.0.1:${toString backendPort}";
in {
  imports = [ inputs.hermes-webui.nixosModules.default ];

  services.hermes-webui = {
    enable = true;
    # Paquet amont + patch local : le WebUI n'écrit son titre de session qu'à
    # la fin d'un run (et jamais si le run est interrompu), donc la sidebar
    # affiche le premier message brut pendant tout le run. Le moteur Hermes
    # (hermes_state) a déjà le bon titre dans state.db quelques secondes après
    # le premier message. core_title_adoption.py démarre un watchdog qui
    # recopie ce titre dans le sidecar du WebUI (state.db ouvert en lecture
    # seule, désactivable par HERMES_WEBUI_CORE_TITLE_ADOPTION=0).
    # À retirer quand le comportement existe en amont dans l'input.
    package = inputs.hermes-webui.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        chmod u+w $out/hermes-webui/api
        install -m 0644 ${./core_title_adoption.py} $out/hermes-webui/api/core_title_adoption.py
        install -m 0644 ${./api_init.py} $out/hermes-webui/api/__init__.py
      '';
    });

    # même compte que le service hermes : il doit lire/écrire l'état du profil
    user = "hermes";
    group = "hermes";

    host = "127.0.0.1";
    port = backendPort;

    # état du WebUI (sessions propres au WebUI, caches) : sous le profil, pas
    # dans /var/lib/hermes-webui, pour rester dans le périmètre du profil et
    # du ProtectSystem du service hermes si on l'y rattache un jour.
    stateDir = "${profileDir}/webui";

    hermesHome = profileDir;

    # HERMES_WEBUI_PYTHON est déduit de passthru.hermesVenv du paquet agent :
    # c'est cet interpréteur qui importe run_agent (vérifié : le bootstrap
    # relance server.py avec lui). Pas de agent.dir explicite : la découverte
    # par l'interpréteur trouve site-packages tout seul.
    agent.package = config.services.hermes-agent.package;

    # clés de provider du profil pocket (OPENROUTER_API_KEY, KIMI_API_KEY…).
    # Le module refuse les clés WebUI protégées (HOST/PORT/STATE_DIR/...) ici.
    environmentFiles = ["${profileDir}/.env"];

    extraEnvironment = {
      HERMES_WEBUI_ISOLATED_PROFILE = "1";
      # cwd du serveur (le reste du store nix est en lecture seule)
      HERMES_WEBUI_SERVER_CWD = "/var/lib/hermes";
      # nginx réécrit Host: 127.0.0.1:9130 (cf. plus haut), donc le garde CSRF
      # du backend (api/routes.py: _check_same_origin_browser_request) voit un
      # Origin (https://hermes-mobile.marcpartensky.com) qui ne matche jamais
      # le Host réécrit -> "Cross-origin mismatch". On déclare explicitement
      # l'origine publique comme fiable plutôt que de faire confiance à
      # X-Forwarded-Host (HERMES_WEBUI_TRUST_FORWARDED_HOST), Pangolin/newt
      # n'étant pas garanti de le poser.
      HERMES_WEBUI_ALLOWED_ORIGINS = "https://hermes-mobile.marcpartensky.com";
    };
  };

  # Proxy local : le serveur du WebUI vérifie le Host, et nginx est le seul
  # point d'entrée loopback. Même mécanique que services/hermes-dashboard.
  services.nginx.virtualHosts."hermes-webui-proxy" = {
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
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
      '';
    };
  };

  # Ressource publique Pangolin, appliquée par le site qui porte le blueprint
  # (donc tower) : `site` est omis volontairement, cf. services/newt.
  # NB : cle `proxy-resources` + `protocol` (schema attendu par le Pangolin du
  # VPS), cf. le commentaire detaille dans services/newt.
  services.newt.blueprint.proxy-resources.hermes-webui = {
    name = "Chat web Hermes";
    protocol = "http";
    full-domain = "hermes-mobile.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = proxyPort;
        method = "http";
      }
    ];
  };

  # Garde-fou : ces ports ne doivent jamais être ouverts sur le LAN.
  assertions = [
    {
      assertion = !(lib.elem backendPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-webui : le port ${toString backendPort} (API + PTY sans mot de passe) ne doit pas être ouvert au firewall.";
    }
    {
      assertion = !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-webui : le port ${toString proxyPort} (proxy du backend) ne doit pas être ouvert au firewall.";
    }
  ];
}
