{ pkgs, config, lib, ... }:
{
  sops.secrets."tailscale/auth_key" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;
  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = lib.mkDefault 1;

  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "both"; # "client", "server" ou "both" si ce nœud est aussi exit node / subnet router
    authKeyFile = config.sops.secrets."tailscale/auth_key".path;
    extraUpFlags = [
      "--login-server=https://headscale.marcpartensky.com" # contrôleur auto-hébergé (headscale), pas le tailscale officiel
      "--accept-routes"
    ];
  };

  networking.firewall.trustedInterfaces = [ "tailscale0" ];
}
