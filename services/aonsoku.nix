# services/aonsoku/default.nix
# Aonsoku (github.com/victoralvesf/aonsoku) on music.marcpartensky.com.
#
# Modern web client for Navidrome/Subsonic (React + Electron, MIT): it is a SPA
# served by nginx in the image; the whole music call goes from the BROWSER to
# SERVER_URL, so the container needs no outbound network access to
# Navidrome, and no data is persisted (state in localStorage).
#
# The SPA has NO auth of its own: no account, no OIDC, no backend. The image
# renders /usr/share/nginx/html/env-config.js from the container env at startup,
# so the Subsonic credentials are injected with APP_USER/APP_PASSWORD
# (deploy/containers.nix + the sops secret below) and the browser logs itself in:
# no prompt. The account is a DEDICATED non-admin Navidrome user ("aonsoku"), so
# marc's own account password never enters the repo.
#
# CONSEQUENCE, and the reason the Pangolin gate below is now the ONLY
# authentication of the app: window.APP_PASSWORD is served to whoever loads the
# page. Setting auth.sso-enabled = false while the autologin is on would publish
# that password to the whole internet. To go back to a double login, drop
# APP_USER / APP_AUTH_TYPE / envFiles from deploy/containers.nix.
#
# Why it works although Navidrome is behind the Pangolin SSO: Aonsoku talks to
# https://navidrome.marcpartensky.com/rest/*, and these paths are excluded from
# the gate by ACCEPT rules on the Pangolin side (cf. services/navidrome). The
# credentials come from the container env, not from nix.
#
# No nixpkgs package: OCI container via podman quadlet
# (deploy/containers.nix `aonsoku` entry, rendered by deploy/render.sh: changing
# the image, the port or a variable costs no eval and no NixOS generation).
{
  config,
  lib,
  pkgs,
  ...
}: {
  # The container is no longer declared here: it moved out of the host config into
  # deploy/containers.nix (`aonsoku` entry, migrated = true) and runs as a
  # rootless podman quadlet (`aonsoku.service`, file
  # ~hermes/.config/containers/systemd/aonsoku.container written by
  # deploy/render.sh, user scope).
  # Takeover (order documented in deploy/containers.nix):
  # `just deploy aonsoku --takeover` BEFORE the switch that removes this block,
  # otherwise the container is deleted without a replacement.
  #
  # What remains here, and must remain: the newt/Pangolin route below, plus the
  # sops declaration of the autologin password.

  # Dotenv read by the quadlet (EnvironmentFile=/run/secrets/aonsoku_env): one
  # APP_PASSWORD line. Owner hermes because the quadlet runs in hermes's user
  # session; render.sh refuses to restart a container whose envFiles are missing.
  #
  # The Navidrome account itself is NOT in nix: it is a real user in
  # navidrome.db, created once with the CLI (the account, not the secret, is
  # state). To recreate or rotate it:
  #   /var/lib/hermes/workspace/aonsoku-user/create-aonsoku-user.sh  (root:
  #   it writes in /var/lib/navidrome; it regenerates the password, checks it
  #   against the running server, and drops it in /var/lib/hermes/.aonsoku-pw
  #   for the agent to re-encrypt into secrets/aonsoku.yml with sops).
  # Aonsoku needs APP_USER + APP_PASSWORD + APP_AUTH_TYPE + SERVER_URL +
  # HIDE_SERVER together: the SPA only enables the autologin when all five are
  # set (window flags read in env-config.js).
  sops.secrets."aonsoku_env" = {
    sopsFile = ../secrets/aonsoku.yml;
    owner = "hermes";
  };

  # Public exposure: music.marcpartensky.com -> 127.0.0.1:8099, with the
  # Pangolin SSO (Zitadel) like the other UIs.
  # NB: `auth.sso-enabled` gates the resource, but the blueprint does not carry a
  # field to go directly to the IdP: `resources.skipToIdpId = 1` is set
  # in the Pangolin database (as for navidrome), otherwise the proxy's internal login page
  # shows before Zitadel. To set again if the resource is recreated (uuid
  # that changes).
  services.newt.blueprint.proxy-resources.aonsoku = {
    name = "aonsoku";
    protocol = "http";
    full-domain = "music.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8099;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8099;
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
}
