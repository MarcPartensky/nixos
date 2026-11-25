# services/tunnel-health: health of marc's SSH aliases and reverse tunnels.
#
# Chain: Pangolin (tunnel.marcpartensky.com, SSO) -> newt (site tower)
#          -> 127.0.0.1:9144 (tunnel-health-web).
#
# Two units, two users:
#
#   tunnel-health-probe  (User=hermes, timer 60 s): a single ssh connection
#     to the VPS to read the SSH banner of the reverse ports on loopback
#     (2222/2223/2224/2226), plus the LAN aliases directly. Writes
#     /var/lib/tunnel-health/{status.json,index.html}. Runs as hermes because
#     it is the account that already has the VPS root key: no additional key
#     nor authorized_keys line to add on the VPS side.
#
#   tunnel-health-web    (User=tunnel-health, read-only): serves the page on
#     the loopback. The HTTP server therefore has no ssh access: a parsing bug
#     does not give the VPS.
#
# Nothing is opened in the firewall: access goes through newt + Pangolin SSO.
{ config, lib, pkgs, ... }:
let
  port = 9144;

  # `via` = measurement path:
  #   lan    direct connection from tower (home LAN, no mesh)
  #   local  tower loopback (wstunnel entry points)
  #   rack   a single ssh session to the VPS, then /dev/tcp on its loopback:
  #          it is the only place where the reverse tunnels are visible.
  endpoints = [
    {
      alias = "towerlocal";
      via = "lan";
      host = "192.168.1.44";
      port = 22;
      target = "192.168.1.44:22";
      user = "marc";
      purpose = "tower on the LAN, if the mesh is down";
    }
    {
      alias = "maclan";
      via = "lan";
      host = "192.168.1.48";
      port = 22;
      target = "192.168.1.48:22";
      user = "marc";
      purpose = "Mac on the LAN (DHCP IP, may move)";
    }
    {
      alias = "mactun";
      via = "rack";
      port = 2223;
      target = "rack:2223";
      user = "marc";
      purpose = "Mac via its autossh reverse tunnel (launchd)";
    }
    {
      alias = "phonetun";
      via = "rack";
      port = 2224;
      target = "rack:2224";
      user = "nix-on-droid";
      purpose = "phone via its reverse tunnel (-> 8023)";
    }
    {
      alias = "tunnel";
      via = "rack";
      port = 2222;
      target = "rack:2222";
      user = "marc";
      purpose = "tower via its autossh reverse tunnel (-> 22), not wstunnel";
    }
    {
      alias = "vpsws";
      via = "local";
      port = 2222;
      target = "127.0.0.1:2222 (tower)";
      user = "root";
      purpose = "VPS via wstunnel: client absent from tower, dead alias";
    }
    {
      alias = "phonews";
      via = "local";
      port = 2225;
      target = "127.0.0.1:2225 (tower)";
      user = "nix-on-droid";
      purpose = "phone via the same wstunnel: client absent";
    }
    {
      alias = "tablet";
      via = "rack";
      port = 2226;
      target = "rack:2226";
      user = "nix-on-droid";
      purpose = "nix-on-droid tablet, its own tunnel";
    }
  ];

  endpointsFile = pkgs.writeText "tunnel-health-endpoints.json" (builtins.toJSON endpoints);
  script = ./tunnel_health.py;

  # Hardening common to both units.
  hardening = {
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
  };
in
{
  users.users.tunnel-health = {
    isSystemUser = true;
    group = "tunnel-health";
    description = "Serves the tunnel health page (read-only)";
  };
  users.groups.tunnel-health = { };

  systemd.services.tunnel-health-probe = {
    description = "Health probe of SSH aliases and reverse tunnels";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.openssh ];

    serviceConfig = hardening // {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      # HOME is required by the ssh client; the key lives in its ~/.ssh.
      Environment = [
        "HOME=/var/lib/hermes"
        "TUNNEL_HEALTH_DIR=/var/lib/tunnel-health"
        "TUNNEL_HEALTH_ENDPOINTS=${endpointsFile}"
        "TUNNEL_HEALTH_RACK_HOST=root@marcpartensky.com"
        "TUNNEL_HEALTH_SSH_KEY=/var/lib/hermes/.ssh/id_ed25519"
        "TUNNEL_HEALTH_KNOWN_HOSTS=/var/lib/hermes/.ssh/known_hosts"
      ];
      StateDirectory = "tunnel-health";
      # 0755: the web unit (another user) must be able to read the snapshot.
      StateDirectoryMode = "0755";
      ExecStart = "${pkgs.python3}/bin/python3 ${script} probe";
      TimeoutStartSec = "45s";
      # Non-zero exit = at least one alias down; this is not a failure of
      # the unit (the timer must keep measuring), so no Restart.
      SuccessExitStatus = "0 1";
    };
  };

  systemd.timers.tunnel-health-probe = {
    description = "Tunnel health probe every 60 s";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "20s";
      OnUnitInactiveSec = "60s";
      AccuracySec = "5s";
      Unit = "tunnel-health-probe.service";
    };
  };

  systemd.services.tunnel-health-web = {
    description = "Tunnel health page (loopback, behind Pangolin)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = hardening // {
      Type = "simple";
      User = "tunnel-health";
      Group = "tunnel-health";
      Environment = [
        "TUNNEL_HEALTH_DIR=/var/lib/tunnel-health"
        "TUNNEL_HEALTH_PORT=${toString port}"
      ];
      ExecStart = "${pkgs.python3}/bin/python3 ${script} web --host 127.0.0.1 --port ${toString port}";
      Restart = "always";
      RestartSec = 3;
      # Read-only of the snapshot written by the probe; the "-" tolerates the
      # folder missing on the very first startup.
      ReadOnlyPaths = [ "-/var/lib/tunnel-health" ];
    };
  };

  # The page is reachable only by newt (Pangolin SSO): never in clear.
  services.newt.blueprint.proxy-resources.tunnel-health = {
    name = "tunnel-health";
    protocol = "http";
    full-domain = "tunnel.marcpartensky.com";
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
      message = "tunnel-health: port ${toString port} must not be open in the firewall (newt + SSO only).";
    }
  ];
}
