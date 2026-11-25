# services/hermes-webapp/default.nix
# Hermes Webapp: the front of the DESKTOP app served in a browser.
#
# This is not the dashboard (services/hermes-dashboard, dash.marcpartensky.com)
# nor the third-party WebUI (services/hermes-webui): it is the desktop's React renderer,
# served by the default profile's GATEWAY on its own listener
# (`gateway/webapp_listener.py`, `webapp:` in config.yaml). A single
# conversation, shared with the CLI, the native desktop and Matrix, since it is
# the same gateway process serving everyone.
#
# Chain: Pangolin (hermes.marcpartensky.com, `hermes-webui` resource of the
#          newt blueprint, target retargeted to this proxy)
#          -> 127.0.0.1:9124 (nginx)
#          -> 127.0.0.1:9123 (gateway Webapp listener, default profile)
#
# Why nginx does NOT rewrite Host here (unlike hermes-dashboard):
# `webapp.public_url` declares the public host as a trusted host of the listener
# (`web_server_boundary._is_accepted_host`), so the anti-DNS-rebinding guard and
# the WebSocket Origin validation (`/api/ws`) accept the real Host. Rewriting it
# to 127.0.0.1:9123 would make the WS guard reject the Origin.
#
# Auth: `public_url` ENGAGES the dashboard login gate even on a loopback
# bind (`listener_auth_required` + `public_hosts_engage_gate`). The provider
# is the simple password (plugins/dashboard_auth/basic), fed by the
# sops file `hermes_webapp_gate_env` (identifier, password, session
# signing key). No secret value enters the nix store.
#
# Isolation: the Webapp serves ONE profile, so ONE agent. Anyone who passes
# the gate sees ALL the sessions of that profile (no partitioning per
# account). Hence a single-user gate as long as there is only one profile; one
# user per person = one profile + one standalone gateway per person.
{
  config,
  lib,
  ...
}: let
  webappPort = 9123;
  proxyPort = 9124;
  webappHost = "127.0.0.1:${toString webappPort}";
  publicUrl = "https://hermes.marcpartensky.com";
in {
  # The gateway re-reads `webapp` at startup: a switch only sets the
  # config (restartIfChanged = false on the unit side), the listener appears at the
  # next gateway restart.
  services.hermes-agent.settings.webapp = {
    enabled = true;
    host = "127.0.0.1";
    port = webappPort;
    public_url = publicUrl;
  };

  # Gate: identifier + password (hashed in memory at startup) + signing
  # key. dotenv content, concatenated into $HERMES_HOME/.env at activation.
  sops.secrets."hermes_webapp_gate_env" = lib.mkIf config.services.hermes.enableAgent {
    key = "hermes_webapp_gate_env";
    sopsFile = ../../secrets/hermes-webapp.yml;
    owner = config.services.hermes-agent.user;
    group = config.services.hermes-agent.group;
    mode = "0400";
  };

  services.hermes-agent.environmentFiles = lib.mkIf config.services.hermes.enableAgent [
    config.sops.secrets."hermes_webapp_gate_env".path
  ];

  services.nginx.virtualHosts."hermes-webapp-proxy" = {
    listen = [
      {
        addr = "127.0.0.1";
        port = proxyPort;
      }
    ];
    locations."/" = {
      proxyPass = "http://${webappHost}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
      '';
    };
  };

  # Safeguard: never a port at the firewall (the Webapp gives a full shell).
  assertions = [
    {
      assertion = !(lib.elem webappPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-webapp: port ${toString webappPort} (desktop front, tools and terminal) must not be opened at the firewall.";
    }
    {
      assertion = !(lib.elem proxyPort config.networking.firewall.allowedTCPPorts);
      message = "hermes-webapp: port ${toString proxyPort} (Webapp listener proxy) must not be opened at the firewall.";
    }
  ];
}
