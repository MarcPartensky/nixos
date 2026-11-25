{ config, lib, pkgs, ... }:
let
  cfg = config.meshTailscale;
  routesArg = lib.concatStringsSep "," cfg.advertiseRoutes;
  setFlags = [
    "--advertise-exit-node=${lib.boolToString cfg.advertiseExitNode}"
    # an empty value erases the previously advertised routes (idempotence:
    # a node that must no longer advertise is actively cleaned up)
    "--advertise-routes=${routesArg}"
  ];
in
{
  # tailscale node of marc's headscale mesh (see services/headscale for the
  # controller, which runs on the `anywhere` VPS). To import on each NixOS
  # machine of the flake: tower, deck, anywhere, laptop...
  #
  # Automatic enrollment: shared reusable pre-authentication key,
  # in secrets/headscale.yml (key `preauth_key`; recipients anywhere,
  # tower, mac, deck-host). Rotation: see the bottom of the headscale module.
  #
  # Hardening: disableUpstreamLogging cuts the sending of tailscaled logs
  # to Tailscale Inc (equivalent of --no-logs-no-support); the controller
  # only advertises the VPS's DERP, never the tailscale.com fleet.
  #
  # Exit node / subnets: this is PER HOST, via the meshTailscale options.
  # The advertised routes must then be approved on the controller side:
  #   headscale nodes approve-routes --identifier <id> --routes 0.0.0.0/0,::/0,192.168.1.0/24
  options.meshTailscale = {
    advertiseExitNode = lib.mkEnableOption "advertise this node as a tailnet exit node";

    # Nodes already enrolled in headscale (the laptop, whose state lives in
    # /var/lib/tailscale): the pre-authentication key is no longer needed,
    # and above all secrets/headscale.yml does not list their age key, so
    # declaring it fails the sops manifest of the WHOLE host.
    enablePreauthKey = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Declare secrets/headscale.yml (pre-authentication key) on this host.";
    };

    advertiseRoutes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Subnets advertised to the tailnet (e.g. the home LAN from tower).";
    };
  };

  config = {
    # First-enrollment pitfall: tailscaled-autoconnect.service has 90 s to
    # reach the controller. If the public endpoint is not ready yet (Traefik
    # cert being issued, route absent), it times out and the node
    # stays unenrolled. Once the endpoint is OK:
    #   sudo systemctl restart tailscaled-autoconnect.service   (or a reboot)
    sops.secrets."headscale/preauth_key" = lib.mkIf cfg.enablePreauthKey {
      sopsFile = ../../secrets/headscale.yml;
      key = "preauth_key";
      owner = "root";
      group = "root";
      mode = "0400";
    };

    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = lib.mkDefault 1;

    services.tailscale = {
      enable = true;
      openFirewall = true;
      # "both": this node can also advertise subnets / be an exit node.
      useRoutingFeatures = "both";
      authKeyFile = lib.mkIf cfg.enablePreauthKey config.sops.secrets."headscale/preauth_key".path;
      extraUpFlags = [
        "--login-server=https://headscale.marcpartensky.com" # self-hosted controller, not Tailscale Inc
        "--accept-routes"
      ]
      ++ lib.optional cfg.advertiseExitNode "--advertise-exit-node"
      ++ lib.optional (cfg.advertiseRoutes != [ ]) "--advertise-routes=${routesArg}";
      disableUpstreamLogging = true;
    };

    networking.firewall.trustedInterfaces = [ "tailscale0" ];

    # The flags passed to `tailscale up` are only applied by
    # tailscaled-autoconnect at login time: on an already connected node
    # `tailscale set` is needed. This unit makes the advertisement declarative and
    # idempotent, reapplied on every boot.
    systemd.services.tailscale-advertise = {
      description = "Tailscale: advertise exit node / subnets";
      wantedBy = [ "multi-user.target" ];
      requires = [ "tailscaled.service" ];
      after = [ "tailscaled.service" "tailscaled-autoconnect.service" ];
      wants = [ "tailscaled-autoconnect.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.services.tailscale.package}/bin/tailscale set ${lib.concatStringsSep " " setFlags}";
      };
    };
  };
}
