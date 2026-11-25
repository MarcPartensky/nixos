# services/hermes-webui/default.nix
# Hermes chat web UI (community project github:nesquena/hermes-webui,
# flake input) running on the "pocket" profile, isolated from the Matrix gateway.
#
# Chain: Pangolin (hermes.marcpartensky.com, SSO)
#          -> newt (site tower)
#          -> 127.0.0.1:9131 (nginx, rewrites Host: 127.0.0.1:9130)
#          -> 127.0.0.1:9130 (services.hermes-webui).
#
# The server runs the agent IN PROCESS (no gateway API): it therefore reads the
# HERMES_HOME we give it. Two pitfalls verified on 25/09/2026:
#  1. HERMES_HOME alone is NOT enough: without HERMES_WEBUI_ISOLATED_PROFILE=1 the
#     server falls back to the default profile and writes into the root
#     state.db (/var/lib/hermes/.hermes/state.db), shared with the Matrix
#     gateway and the CLI sessions. With the flag, the active profile does become
#     pocket and only its own database is touched.
#  2. There is NO authentication guard on a loopback address (it
#     only activates on a non-loopback address). It is the Pangolin SSO that
#     protects access, exactly like terminal.marcpartensky.com. Never
#     open 9130/9131 in the firewall: the server also exposes a PTY (/api/pty)
#     and the full API (sessions, memory, files) without a password.
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
  # Loopback proxy of the official Webapp (services/hermes-webapp): it is it
  # that the Pangolin resource in this file targets since 14/11/2026.
  webappProxyPort = 9124;
  backendUrl = "http://127.0.0.1:${toString backendPort}";
  backendHost = "127.0.0.1:${toString backendPort}";
in {
  imports = [ inputs.hermes-webui.nixosModules.default ];

  # A NixOS rebuild must not cut the WebUI: the runs in progress live
  # inside it. The new config applies at the next startup.
  systemd.services.hermes-webui.restartIfChanged = false;

  # The pocket profile must belong to hermes: the service (user hermes) creates
  # its stateDir <profile>/webui at startup and fails with EACCES if the directory
  # is root:hermes (experienced 24/11/2026, profile recreated as root after the
  # move of 20/11). `z` realigns an EXISTING path at each activation,
  # `d` would do nothing on an already-present directory.
  systemd.tmpfiles.rules = [
    "d ${profileDir} 0700 hermes hermes -"
    "z ${profileDir} 0700 hermes hermes -"
  ];

  services.hermes-webui = {
    enable = true;
    # Upstream package + local patch: the WebUI only writes its session title at
    # the end of a run (and never if the run is interrupted), so the sidebar
    # shows the raw first message during the whole run. The Hermes engine
    # (hermes_state) already has the right title in state.db a few seconds after
    # the first message. core_title_adoption.py starts a watchdog that
    # copies that title into the WebUI sidecar (state.db opened read-
    # only, disableable with HERMES_WEBUI_CORE_TITLE_ADOPTION=0).
    # To remove when the behavior exists upstream in the input.
    package = inputs.hermes-webui.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        chmod u+w $out/hermes-webui/api
        install -m 0644 ${./core_title_adoption.py} $out/hermes-webui/api/core_title_adoption.py
        install -m 0644 ${./api_init.py} $out/hermes-webui/api/__init__.py
      '';
    });

    # same account as the hermes service: it must read/write the profile state
    user = "hermes";
    group = "hermes";

    host = "127.0.0.1";
    port = backendPort;

    # WebUI state (WebUI-specific sessions, caches): under the profile, not
    # in /var/lib/hermes-webui, to stay within the scope of the profile and
    # of the ProtectSystem of the hermes service if we ever attach it there.
    stateDir = "${profileDir}/webui";

    hermesHome = profileDir;

    # HERMES_WEBUI_PYTHON is derived from passthru.hermesVenv of the agent package:
    # it is this interpreter that imports run_agent (verified: the bootstrap
    # relaunches server.py with it). No explicit agent.dir: the
    # discovery by the interpreter finds site-packages on its own.
    agent.package = config.services.hermes-agent.package;

    # provider keys of the pocket profile (OPENROUTER_API_KEY, KIMI_API_KEY...).
    # The module refuses the protected WebUI keys (HOST/PORT/STATE_DIR/...) here.
    environmentFiles = ["${profileDir}/.env"];

    extraEnvironment = {
      HERMES_WEBUI_ISOLATED_PROFILE = "1";
      # cwd of the server (the rest of the nix store is read-only)
      HERMES_WEBUI_SERVER_CWD = "/var/lib/hermes";
      # nginx rewrites Host: 127.0.0.1:9130 (cf. above), so the CSRF guard
      # of the backend (api/routes.py: _check_same_origin_browser_request) sees an
      # Origin (https://hermes.marcpartensky.com) that never matches
      # the rewritten Host -> "Cross-origin mismatch". We explicitly declare
      # the public origin as trusted rather than trusting
      # X-Forwarded-Host (HERMES_WEBUI_TRUST_FORWARDED_HOST), Pangolin/newt
      # not being guaranteed to set it.
      HERMES_WEBUI_ALLOWED_ORIGINS = "https://hermes.marcpartensky.com";

      # --- OIDC Zitadel (option a, 19/10/2026) ---
      # The WebUI application auth replaces the Pangolin SSO (see the
      # blueprint below). Zitadel app "Hermes WebUI" (User Agent, public
      # PKCE without secret, client_id 395733475048620332, exact
      # registered redirect). allow_claim=preferred_username: claim present
      # in the ID token (Zitadel claims matrix) and equal to marc's Zitadel
      # username. PREREQUISITE ON THE ZITADEL SIDE (state in the database, not in this
      # file): the "Hermes WebUI" app must keep "User Info inside ID
      # Token" (idTokenUserinfoAssertion) ENABLED. Without it, Zitadel emits
      # no scope claim (profile/email) in the id_token as soon as an
      # access_token is issued: preferred_username is absent and the WebUI
      # responds 403 "OIDC identity is not allowed" after a nonetheless
      # successful login (verified on 11/11/2026). The WebUI does NOT fall back on
      # /userinfo, the claim must come from the id_token.
      # Explicit REDIRECT_URI because nginx rewrites the Host
      # to 127.0.0.1:9130 (the derived redirect would be wrong).
      HERMES_WEBUI_OIDC_ISSUER = "https://auth.marcpartensky.com";
      HERMES_WEBUI_OIDC_CLIENT_ID = "395733475048620332";
      HERMES_WEBUI_OIDC_ALLOW_CLAIM = "preferred_username";
      HERMES_WEBUI_OIDC_ALLOW_VALUES = "marc@marcpartensky.com";
      HERMES_WEBUI_OIDC_REDIRECT_URI = "https://hermes.marcpartensky.com/api/auth/oidc/callback";
    };
  };

  # Local proxy: the WebUI server checks the Host, and nginx is the only
  # loopback entry point. Same mechanism as services/hermes-dashboard.
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

  # Public Pangolin resource, applied by the site that carries the blueprint
  # (hence tower): `site` is omitted on purpose, cf. services/newt.
  # NB: key `proxy-resources` + `protocol` (schema expected by the Pangolin of the
  # VPS), cf. the detailed comment in services/newt.
  #
  # Domain: this domain now carries the official WEBAPP (desktop
  # front, services/hermes-webapp, proxy 9124), not the third-party WebUI: the
  # Pangolin resource is kept HERE (same blueprint name, so updated
  # in place, without risk of a domain duplicate) but its target points to the
  # Webapp proxy. The WebUI stays served on loopback (9131) for comparison.
  # WARNING: a manual Pangolin resource (id 22, name "hermes") already
  # occupies hermes.marcpartensky.com on the VPS side (target tower:10274, dead port).
  # As long as it exists, two Traefik routers will target the same host.
  services.newt.blueprint.proxy-resources.hermes-webui = {
    name = "hermes-webui";
    protocol = "http";
    full-domain = "hermes.marcpartensky.com";
    # Pangolin SSO left disabled: the Webapp carries its own
    # login gate (password, committed by webapp.public_url). A single
    # auth layer, no double login.
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = webappProxyPort;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = webappProxyPort;
          path = "/";
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

  # Guardrail: these ports must never be opened on the LAN.
  assertions = [
    {
      assertion = !(lib.elem backendPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-webui: port ${toString backendPort} (API + PTY without password) must not be opened in the firewall.";
    }
    {
      assertion = !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-webui: port ${toString proxyPort} (backend proxy) must not be opened in the firewall.";
    }
  ];
}
