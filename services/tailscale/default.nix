{ pkgs, config, ... }:
{
  sops.secrets."tailscale/auth_key" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "both"; # "client", "server" ou "both" si ce nœud est aussi exit node / subnet router
    authKeyFile = config.sops.secrets."tailscale/auth_key".path;
    extraUpFlags = [
      "--accept-routes"
      "--advertise-tags=tag:server" # si tu utilises des ACL tags dans ton tailnet
    ];
  };

  networking.firewall.trustedInterfaces = [ "tailscale0" ];
}
