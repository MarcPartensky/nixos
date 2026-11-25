# services/shlink-web-client/default.nix
# Shlink administration web client (github.com/shlinkio/shlink-web-client)
# on shlink.marcpartensky.com.
#
# Shlink itself has NO UI (services/shlink only exposes the REST API on
# s.marcpartensky.com): this container serves the official React PWA. Everything goes from
# the BROWSER to the API (the app is 100% client), so the container needs
# no outbound network access and persists nothing: the state (servers, API
# key) lives in the browser's localStorage.
#
# Pangolin SSO ACTIVE here, unlike s.marcpartensky.com: a short link
# must resolve for anyone, an admin console must not. The Shlink API is
# already protected by its key, this protects the interface that manipulates it.
#
# No nixpkgs package: OCI container (nginx:alpine + static build), same
# pattern as services/aonsoku and services/chhoto.
#
# The API key is DELIBERATELY not pre-filled. SHLINK_SERVER_API_KEY
# would make servers.json be written in clear text in the web root served by nginx, which
# is exactly the "clear-text secret" the repo avoids (and the project's
# README warns against it). Only the server URL is pre-filled: the key
# is entered once in the UI and stays in the browser.
{
  config,
  lib,
  pkgs,
  ...
}: let
  port = 8100;
  domain = "shlink.marcpartensky.com";
in {
  # Container taken out of the host conf: deploy/containers.nix (entry
  # `shlink-web-client`, migrated = true), podman quadlet
  # `shlink-web-client.service`. Changing the image no longer requires an eval or
  # switch. Takeover: `just deploy shlink-web-client --takeover` BEFORE the
  # switch that removes this block.
  #
  # Stays here, and must stay: the newt/Pangolin route below.

  # Public exposure: shlink.marcpartensky.com -> 127.0.0.1:8100, with
  # Pangolin SSO (Zitadel) like the other UIs.
  # NB: `auth.sso-enabled` gates the resource, but the blueprint does not carry a
  # field to go directly to the IdP: `resources.skipToIdpId = 1` is set
  # in the Pangolin DB (as for navidrome and aonsoku), otherwise the proxy's
  # internal login page shows before Zitadel.
  services.newt.blueprint.proxy-resources.shlink-admin = {
    name = "shlink-admin";
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

  # -- Guard rails -------------------------------------------------------
  assertions = [
    {
      # The port must stay on loopback: the UI has no password of its own,
      # the only bulwark is the proxy (SSO) and therefore the absence of LAN exposure.
      assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
      message = "shlink-web-client: port ${toString port} must not be opened to the firewall (exposure only via Pangolin/newt).";
    }
  ];
}