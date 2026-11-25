# services/hermes-mobile/default.nix
# Backend of the "Hermes Mobile" mobile app (F-Droid, com.m57.hermescontrol):
# `hermes serve --isolated` on tower's DEFAULT profile, so the SAME agent
# as the Matrix gateway (hermes-agent), the dashboard (hermes-dashboard) and the
# desktop sessions. This module replaces the old backend on the isolated
# "pocket" profile (services/hermes-pocket): the mobile app now sees
# the history, memory, skills and model of the default profile instead of
# a separate profile.
#
# Chain: Pangolin (hermes-mobile.marcpartensky.com, SSO DISABLED)
#          -> newt (site tower)
#          -> 127.0.0.1:9129 (nginx, rewrites Host: 127.0.0.1:9119)
#          -> 127.0.0.1:9119 (hermes serve --isolated, HERMES_HOME default).
#
# Why --isolated: the machine's "unified" server is already the dashboard's
# (127.0.0.1:9120). Without --isolated, `hermes serve` refuses to start
# (exit 78, "this host is already served by PID ..."). --isolated creates a dedicated
# backend, as Hermes Desktop does for its SSH connections. Several backends
# on the same state.db are normal: this is already the case for the gateway, the dashboard
# and the desktop's SSH backends.
#
# Native auth gate ACTIVE: mobile-serve.env (0600, off the nix store) declares
# HERMES_DASHBOARD_PUBLIC_URL=https://hermes-mobile.marcpartensky.com +
# HERMES_DASHBOARD_BASIC_AUTH_*; a non-loopback public_url engages
# auth_required=true even on a loopback bind (upstream doctrine). Without this
# gate, the headless server would serve the root page with
# window.__HERMES_SESSION_TOKEN__ in clear behind a Pangolin resource without
# SSO: session token leak (incident of 19/10/2026, cf. pocket history).
#
# Client flow ("Hermes Mobile" F-Droid app, Username & Password mode):
# POST /auth/password-login (basic provider, credentials in mobile-serve.env)
# -> session cookies -> POST /api/auth/ws-ticket
# -> ws(s)://<domain>/api/ws?ticket=<ticket> (single use, TTL 30 s).
#
# Never open 9119 or 9129 on the firewall: the server exposes the agent's
# full API (tools, files, terminal); the auth gate protects access.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # "Hermes vocal" page: duplex web client (VAD + barge-in) served by the same
  # domain as the mobile app, so same-origin with the auth gate (cookies)
  # and the WebSocket. Cf. voice.html.
  voicePage = pkgs.runCommandLocal "hermes-voice-page" {} ''
    mkdir -p $out
    cp ${./voice.html} $out/voice.html
  '';

  # Voice settings service (engine, voice, speed, pitch) + preview
  # synthesis, proxied under /voice/api/ (same origin as the page, so cookies).
  voiceSettingsPort = 9134;
  voiceSettingsState = "/var/lib/hermes/.hermes/voice-settings.json";
  # Interpreter = Hermes's sealed venv (edge-tts 7.3.x is in it). nixpkgs's
  # edge-tts (7.2.8) is rejected by the Microsoft service: 403 "Invalid
  # response status" on the websocket, so the version matters.
  voiceSettingsPython = "${config.services.hermes-agent.package.hermesVenv}/bin/python3";
  voiceSettingsScript = pkgs.writeText "hermes-voice-settings.py"
    (builtins.readFile ./voice-settings.py);

  # Default profile: /var/lib/hermes/.hermes (Nix-managed config, .managed
  # marker written by the NixOS activation, so config writes from the
  # app are refused as from the dashboard).
  profileDir = "/var/lib/hermes/.hermes";
  backendPort = 9119;
  proxyPort = 9129;
  backendUrl = "http://127.0.0.1:${toString backendPort}";
  backendHost = "127.0.0.1:${toString backendPort}";
in {
  systemd.services.hermes-mobile-serve = {
    # A NixOS rebuild must not cut this server: the mobile sessions
    # live inside it. The new config applies at the next startup.
    restartIfChanged = false;
    description = "Hermes serve (default profile): backend of the Hermes Mobile app";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      User = config.services.hermes-agent.user;
      Group = config.services.hermes-agent.group;

      # Same treatment as hermes-agent and hermes-backend: without this line
      # the unit lives in system.slice at weight 100, on the 16 threads, on
      # par with marc's desktop. Measured on 12/11/2026: 37 % of a core
      # continuously with a session open at 2 messages, while the
      # machine was in full swap. hermes.slice confines it to the reserved
      # threads (12-13, weight 2000) like the rest of the Hermes stack.
      Slice = "hermes.slice";

      # same cwd as the app's original session (cf. the project README)
      WorkingDirectory = "/var/lib/hermes/workspace";

      # HERMES_HOME = default profile, and --isolated so as not to
      # conflict with the dashboard's machine backend.
      Environment = [
        "HERMES_HOME=${profileDir}"
        "HERMES_REAL_HOME=/var/lib/hermes"
      ];

      # .env = provider keys of the default profile; mobile-serve.env = auth
      # gate settings (public_url, basic auth). Both off the nix store.
      EnvironmentFile = [
        "${profileDir}/.env"
        "${profileDir}/mobile-serve.env"
      ];

      ExecStart = "${config.services.hermes-agent.package}/bin/hermes serve --isolated --port ${toString backendPort} --host 127.0.0.1";

      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Voice settings: same user as the backend, state in the Hermes home.
  systemd.services.hermes-voice-settings = {
    description = "Hermes vocal: voice settings and preview synthesis";
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

  # Local proxy: the only loopback entry point; it rewrites the Host the
  # server imposes, lets the WebSocket Upgrade through, and announces to the backend
  # https + the real client IP (Secure cookies, audit) via X-Forwarded-*.
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

    # Web voice client (same-origin: auth gate cookies + /api/ws).
    # The page itself contains no secret: the connection is made via the
    # form, then all /api/* requests go back through the proxy above.
    locations."= /voice" = {
      alias = "${voicePage}/voice.html";
      extraConfig = "default_type text/html; add_header Cache-Control \"no-store\";";
    };
    locations."= /voice/" = {
      return = "302 /voice";
    };

    # Voice settings API (state, catalog, previews, synthesis). A prefix
    # more specific than "/": it wins over the backend proxy.
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

  # Pangolin public resource, applied by the site that carries the blueprint
  # (so tower): `site` is omitted on purpose, cf. services/newt.
  # The resource name "hermes-pocket" is kept on purpose: it is
  # the existing identity on the Pangolin side for this domain, renaming it would
  # create a second resource on an already taken domain. Only the backend
  # behind it changed (default profile).
  # No `auth` block: it is the only way to let the native app
  # connect (browser SSO impossible), exactly like the jellyfin
  # resource. The target stays loopback, only nginx is published.
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
          # The guarded root redirects to /login (302); /api/status is the
          # public probe (200) as long as the gate is active.
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

  # Safeguard: these ports must never be opened on the LAN.
  assertions = [
    {
      assertion = !(lib.elem backendPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-mobile: port ${toString backendPort} (full agent API, protected by an auth gate) must not be opened on the firewall.";
    }
    {
      assertion = !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-mobile: port ${toString proxyPort} (backend proxy) must not be opened on the firewall.";
    }
  ];
}
