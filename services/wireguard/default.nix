{pkgs,config,...}:{
  sops.secrets."wireguard/vps_private_key" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  networking.wireguard.interfaces = {
    wg1 = {
      ips = [ "10.100.0.1/24" ];
      listenPort = 51821;
      privateKeyFile = config.sops.secrets."wireguard/vps_private_key".path;
      peers = [
        {
          # macOS MacBook Air
          publicKey = "WB7Wx7GmjpC1XRDFC74ekC7ROlkPmFzrPgIpn4KEOlM=";
          allowedIPs = [ "10.100.0.2/32" ];
        }
      ];
      postSetup = ''
        ${pkgs.iptables}/bin/iptables -A FORWARD -i wg1 -j ACCEPT
        ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
      '';
      postShutdown = ''
        ${pkgs.iptables}/bin/iptables -D FORWARD -i wg1 -j ACCEPT
        ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -o ens3 -j MASQUERADE
      '';
    };
  };
  networking.firewall.allowedUDPPorts = [ 51821 ];
}
