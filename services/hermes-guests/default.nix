# services/hermes-guests/default.nix
# Deux agents Hermes séparés pour Anna et Yves, exposés à l'appli mobile
# « Hermes Mobile » (F-Droid, com.m57.hermescontrol).
#
# Isolation réelle au niveau OS, pas seulement un profil Hermes :
#   - chaque agent tourne sous son propre utilisateur système (anna, yves) ;
#   - HERMES_HOME = /var/lib/<nom>/.hermes : state.db, mémoire, skills et
#     sessions séparés ;
#   - /var/lib/hermes (profil default de marc) est en 2770 hermes:hermes,
#     donc illisible par anna/yves ; aucun accès aux secrets sops ;
#   - aucun accès SSH (pas de clé, pas de mot de passe), aucun groupe
#     supplémentaire, pas de sudo ; chaque agent ne peut écrire que dans son
#     home (ProtectSystem=strict + ReadWritePaths) ;
#   - les outils dangereux sont désactivés dans le config.yaml managed :
#     terminal, file, code_execution, browser, computer_use, delegation,
#     cronjob, connections, image_gen, video, tts, etc. Il reste web, vision,
#     mémoire, todo, session_search, clarify.
#
# Chaîne : Pangolin (hermes-anna/hermes-yves.marcpartensky.com, SSO off)
#          -> newt (site tower)
#          -> 127.0.0.1:9134/9135 (nginx)
#          -> 127.0.0.1:9132/9133 (hermes serve --isolated, anna/yves).
#
# Les identifiants basic auth sont dans
# /var/lib/hermes/guests/<nom>/mobile-serve.env (0400 hermes, illisible par
# les invités, lu par systemd avant le drop de privilèges). La clé OpenRouter
# partagée est dans /var/lib/hermes/guests/llm.env (0400 hermes). Ces fichiers
# sont hors du store nix et survivent aux rebuilds ; les recréer après une
# rotation de mot de passe.
{
  config,
  lib,
  pkgs,
  ...
}: let
  guests = {
    anna = {
      backendPort = 9132;
      proxyPort = 9134;
      domain = "hermes-anna.marcpartensky.com";
    };
    yves = {
      backendPort = 9133;
      proxyPort = 9135;
      domain = "hermes-yves.marcpartensky.com";
    };
  };

  guestConfig = pkgs.writeText "hermes-guest-config.yaml" ''
    model:
      base_url: https://openrouter.ai/api/v1
      default: deepseek/deepseek-v4.1-flash
      context_length: 1048576
      provider: openrouter
      supports_vision: true
    agent:
      max_turns: 40
      disabled_toolsets:
        - terminal
        - file
        - code_execution
        - browser
        - computer_use
        - delegation
        - cronjob
        - connections
        - image_gen
        - video
        - video_gen
        - x_search
        - tts
        - stt
        - kanban
        - homeassistant
        - spotify
        - yuanbao
        - a2a
  '';

  mkGuest = name: guest: let
    # En mode managed (marqueur .managed), Hermes refuse de créer le squelette
    # du home : cron, sessions, logs, memories doivent exister avant le
    # démarrage. On les crée et on (re)copie le config.yaml managé à chaque
    # start, sous l'utilisateur de l'invité (pas de dépendance à tmpfiles).
    preScript = pkgs.writeShellScript "hermes-${name}-pre" ''
      set -eu
      ${pkgs.coreutils}/bin/install -d -m 0700 \
        /var/lib/${name}/.hermes \
        /var/lib/${name}/.hermes/cron \
        /var/lib/${name}/.hermes/sessions \
        /var/lib/${name}/.hermes/logs \
        /var/lib/${name}/.hermes/logs/curator \
        /var/lib/${name}/.hermes/memories \
        /var/lib/${name}/.hermes/pairing \
        /var/lib/${name}/.hermes/hooks \
        /var/lib/${name}/.hermes/image_cache \
        /var/lib/${name}/.hermes/audio_cache \
        /var/lib/${name}/.hermes/skills
      ${pkgs.coreutils}/bin/install -m 0600 ${guestConfig} /var/lib/${name}/.hermes/config.yaml
      echo nixos > /var/lib/${name}/.hermes/.managed
    '';
  in {
    users.groups.${name} = {};

    users.users.${name} = {
      isSystemUser = true;
      group = name;
      home = "/var/lib/${name}";
      createHome = true;
      description = "Agent Hermes de ${name} (accès appli mobile uniquement)";
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/${name} 0700 ${name} ${name} -"
      "d /var/lib/${name}/.hermes 0700 ${name} ${name} -"
      "C /var/lib/${name}/.hermes/config.yaml 0600 ${name} ${name} - ${guestConfig}"
      "f /var/lib/${name}/.hermes/.managed 0644 ${name} ${name} - nixos"
    ];

    systemd.services."hermes-${name}-serve" = {
      description = "Hermes serve (profil ${name}) : agent de ${name} pour l'appli mobile";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      serviceConfig = {
        User = name;
        Group = name;
        WorkingDirectory = "/var/lib/${name}";
        Environment = [
          "HERMES_HOME=/var/lib/${name}/.hermes"
          "HERMES_REAL_HOME=/var/lib/${name}"
          "HOME=/var/lib/${name}"
        ];
        EnvironmentFile = [
          "/var/lib/hermes/guests/llm.env"
          "/var/lib/hermes/guests/${name}/mobile-serve.env"
        ];
        ExecStartPre = preScript;
        ExecStart = "${config.services.hermes-agent.package}/bin/hermes serve --isolated --port ${toString guest.backendPort} --host 127.0.0.1";
        Restart = "on-failure";
        RestartSec = 5;

        # Lecture seule partout sauf le home de l'invité ; /var/lib/hermes
        # reste de toute façon inaccessible (2770 hermes:hermes).
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = false;
        ReadWritePaths = ["/var/lib/${name}"];
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        UMask = "0077";
      };
    };

    services.nginx.virtualHosts."hermes-${name}-proxy" = {
      listen = [
        {
          addr = "127.0.0.1";
          port = guest.proxyPort;
        }
      ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString guest.backendPort}";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_set_header Host 127.0.0.1:${toString guest.backendPort};
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;
          proxy_buffering off;
        '';
      };
      # Pas de shell distant ni de lecture de fichiers arbitraires : le
      # backend exposerait sinon un PTY complet ou /proc/self/environ (qui
      # contient la clé OpenRouter du process) sous l'utilisateur invité.
      locations."~ ^/api/(pty|files/(read|download|stream))(/|$)" = {
        return = "403";
      };
    };

    services.newt.blueprint.proxy-resources."hermes-${name}" = {
      name = "hermes-${name}";
      protocol = "http";
      full-domain = guest.domain;
      targets = [
        {
          hostname = "127.0.0.1";
          port = guest.proxyPort;
          method = "http";
          healthcheck = {
            enabled = true;
            hostname = "127.0.0.1";
            port = guest.proxyPort;
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

    assertions = [
      {
        assertion = !(lib.elem guest.backendPort config.networking.firewall.allowedTCPPorts);
        message = "hermes-guests : le port ${toString guest.backendPort} (API agent de ${name}) ne doit pas être ouvert au firewall.";
      }
      {
        assertion = !(lib.elem guest.proxyPort config.networking.firewall.allowedTCPPorts);
        message = "hermes-guests : le port ${toString guest.proxyPort} (proxy de ${name}) ne doit pas être ouvert au firewall.";
      }
    ];
  };
in {
  config = lib.mkIf config.services.hermes-agent.enable (lib.mkMerge (lib.mapAttrsToList mkGuest guests));
}
