# services/hermes-dashboard/default.nix
# Web terminal + Hermes admin panel on tower.
#
# Nothing to package: the backend is already in the flake's `hermes-agent` input.
# `hermes serve` and `hermes dashboard` are the SAME entry point, one flag
# apart, and both expose the /api/ws and /api/pty sockets. It is /api/pty
# that is the web terminal; `dashboard` additionally adds the browser interface
# on the same port. Only one of the two modes can run per instance.
#
# Chain: Pangolin (dash.marcpartensky.com, SSO)
#          -> newt (site tower)
#          -> 127.0.0.1:9121 (nginx, rewrites Host: 127.0.0.1:9120)
#          -> 127.0.0.1:9120 (hermes-backend.service, dashboard mode).
#
# The domain was terminal.marcpartensky.com until 11/11/2026: that name is
# now taken by the real web terminal (services/terminal, ttyd). A Pangolin domain
# can only carry one resource, hence the move here.
# The Pangolin identifier (niceId) of this resource is `hermes-dashboard`:
# it is a NEW resource (the old one, niceId `hermes-terminal`, is taken over
# by services/terminal, which updates it in place to keep the domain).
#
# The backend bound to loopback does NOT trigger the dashboard's
# authentication guard (it only activates on a non-loopback address): it is the
# Pangolin SSO that protects access, exactly like tower's noVNC resource.
# NEVER expose 9120 or 9121 to the firewall: /api/pty is a shell.
#
# ! The PTY inherits the hardening of the hermes-backend unit (User=hermes).
# Without the `NoNewPrivileges = false` set in services/hermes/default.nix, the
# resulting shell has no sudo, not even the NOPASSWD nixos-rebuild.
{
  config,
  lib,
  ...
}: let
  backendPort = 9120;
  proxyPort = 9121;
  backendUrl = "http://127.0.0.1:${toString backendPort}";
  backendHost = "127.0.0.1:${toString backendPort}";
in {
  # Stable session token: without it the backend regenerates one on each
  # start, which no one else can know (so no external client
  # can attach to THIS backend).
  sops.secrets."hermes_dashboard_token" = {
    sopsFile = ../../secrets/hermes-dashboard.yml;
    key = "hermes_dashboard_token";
    owner = config.services.hermes-agent.user;
    group = config.services.hermes-agent.group;
    mode = "0400";
  };

  services.hermes-agent.backend = {
    mode = "dashboard";
    host = "127.0.0.1";
    port = backendPort;
    sessionTokenFile = config.sops.secrets."hermes_dashboard_token".path;
  };

  # Local proxy: the backend rejects any request whose Host differs from
  # the address it bound to (anti-DNS-rebinding defense), hence the
  # rewrite. Same mechanism as services/hermes-mobile.
  services.nginx.virtualHosts."hermes-dashboard-proxy" = {
    listen = [
      {
        addr = "127.0.0.1";
        port = proxyPort;
      }
    ];
    # `/` covers the web app, /api/ws and /api/pty; proxyWebsockets sets the
    # Upgrade/Connection headers the PTY needs.
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
  # (so tower): `site` is deliberately omitted, cf. services/newt.
  # NB: key `proxy-resources` + `protocol` (schema expected by the VPS
  # Pangolin), cf. the detailed comment in services/newt.
  services.newt.blueprint.proxy-resources.hermes-dashboard = {
    name = "hermes-dashboard";
    protocol = "http";
    full-domain = "dash.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = proxyPort;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = proxyPort;
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

  # Guard rail: these ports must never be opened on the LAN.
  assertions = [
    {
      assertion = !(lib.elem backendPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-dashboard: port ${toString backendPort} (/api/pty = shell) must not be open on the firewall.";
    }
    {
      assertion = !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-dashboard: port ${toString proxyPort} (proxy of /api/pty) must not be open on the firewall.";
    }
  ];
}
