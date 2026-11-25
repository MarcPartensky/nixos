# services/mesh-dashboard: page of marc's tailnet (headscale) nodes.
#
# Chain: Pangolin (mesh.marcpartensky.com, SSO) -> newt (site tower)
#          -> 127.0.0.1:9140 (this service).
# From the tailnet, the direct URL is http://100.64.0.3:9140 (no SSO:
# tailscale0 is already a trusted interface, cf. services/tailscale).
#
# Source of truth: `tailscale status --json` read by tower's client, plus
# `tailscale ping` for the real path of each peer (direct vs DERP). Nothing
# is stored: the page is a reflection of the controller's current state.
#
# The service runs as a dedicated system user, without capability and with a
# read-only filesystem (only /var/run/tailscale is mounted
# read-write for the daemon socket). It only reads: no write
# is needed.
{ config, lib, pkgs, ... }:
let
  port = 9140;

# Gotify application token for transition alerts (node offline
# / back). The token lives in its own sops file, encrypted toward tower
# only, and it is OPTIONAL: as long as the file does not exist, the module
# deploys anyway (the dashboard measures, but does not notify, and shows it
  # in the header "Gotify: missing token").
  #
# Create the token: Gotify (https://gotify.marcpartensky.com, OIDC login)
# -> Apps -> Create Application -> name "mesh-dashboard", then:
#   printf 'mesh_token: %s\n' '<token>' | sops --encrypt \
  #     --filename-override secrets/gotify-mesh.yml --input-type yaml \
  #     /dev/stdin > secrets/gotify-mesh.yml
# (rule `path_regex: secrets/gotify-mesh\.yml$` in .sops.yaml)
  gotifySecretFile = ../../secrets/gotify-mesh.yml;
  gotifyTokenAvailable = builtins.pathExists gotifySecretFile;
  gotifyTokenPath = "/run/secrets/gotify/mesh_token";
in
{
  users.users.mesh-dash = {
    isSystemUser = true;
    group = "mesh-dash";
    description = "Tailnet dashboard (reading tailscaled)";
  };
  users.groups.mesh-dash = { };

  sops.secrets = lib.mkIf gotifyTokenAvailable {
    "gotify/mesh_token" = {
      sopsFile = gotifySecretFile;
      key = "mesh_token";
      owner = "mesh-dash";
      group = "mesh-dash";
      mode = "0400";
    };
  };

  systemd.services.mesh-dashboard = {
    description = "Tailnet (headscale) node dashboard";
    wantedBy = [ "multi-user.target" ];
    wants = [ "tailscaled.service" ];
    after = [ "network.target" "tailscaled.service" ];

    # `tailscale` must be in the unit's PATH: the script calls it as a
    # subprocess (status + ping).
    path = [ pkgs.tailscale ];

    serviceConfig = {
      Type = "simple";
      User = "mesh-dash";
      Group = "mesh-dash";
      Environment = [
        "MESH_DASHBOARD_HOST=0.0.0.0"
        "MESH_DASHBOARD_PORT=${toString port}"
        "MESH_DASHBOARD_STATE=/var/lib/mesh-dashboard/state.json"
        # Gotify runs on tower on loopback: no network egress needed.
        "MESH_DASHBOARD_GOTIFY_URL=https://gotify.marcpartensky.com"
        # Devices to enroll in the tailnet: shown as "pending" as long
        # as they are not seen by the controller. `phone` = marc's Xiaomi
        # (Android Tailscale app, headscale alternate server), `tablet` =
        # upcoming Nix-on-Droid tablet.
        "MESH_DASHBOARD_EXPECTED=phone,tablet"
        # "tunnels" section at the bottom of the page: snapshot written by the
        # services/tunnel-health probe (same host, every 60 s). Read-only:
        # the dashboard measures no tunnel itself.
        "MESH_DASHBOARD_TUNNELS_STATE=/var/lib/tunnel-health/status.json"
      ]
      ++ lib.optional gotifyTokenAvailable "MESH_DASHBOARD_GOTIFY_TOKEN_FILE=${gotifyTokenPath}";

      # Persistent state: "last seen online at" thus survives
      # a service restart (the directory is created and chowned by systemd).
      StateDirectory = "mesh-dashboard";
      StateDirectoryMode = "0750";
      ExecStart = "${pkgs.python3}/bin/python3 ${./mesh_dashboard.py}";
      Restart = "always";
      RestartSec = 3;

      # Hardening: the service only reads a socket and serves only HTTP.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      # The tailscale daemon socket (srw-rw-rw-, cf. tailscaled): read and
      # connect; the dashboard's persistent state (StateDirectory) is the only
      # other writable path.
      ReadWritePaths = [ "/var/run/tailscale" "/var/lib/mesh-dashboard" ];
      # Snapshot of the tunnel-health probe, read for the "tunnels" section.
      # The "-" tolerates the directory being absent on the very first start (the
      # probe runs 20 s after boot).
      ReadOnlyPaths = [ "-/var/lib/tunnel-health" ];
    };
  };

  # The port stays closed at the firewall: it is reached via the tailnet (
  # trusted tailscale0 interface) or via Pangolin SSO through newt, never in clear
  # from the LAN.
  services.newt.blueprint.proxy-resources.mesh-dashboard = {
    name = "mesh-dashboard";
    protocol = "http";
    full-domain = "mesh.marcpartensky.com";
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
          path = "/healthz";
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
      assertion = !(lib.elem port config.networking.firewall.allowedTCPPorts);
      message = "mesh-dashboard: port ${toString port} must not be open at the firewall (tailnet + Pangolin SSO access only).";
    }
  ];
}
