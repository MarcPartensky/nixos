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
      listenPort = 443;
      privateKeyFile = config.sops.secrets."wireguard/vps_private_key".path;
      peers = [
        {
          # macOS MacBook Air
          publicKey = "WB7Wx7GmjpC1XRDFC74ekC7ROlkPmFzrPgIpn4KEOlM=";
          allowedIPs = [ "10.100.0.2/32" ];
        }
        {
          # tower (NixOS, residential NAT): client peer, used for inbound SSH/ET
          # from this VPS and from the Mac. Public key from
          # secrets/wireguard.yml (tower recipient) on tower.
          # 192.168.1.0/24: tower is the router of its LAN (NAT wg1 -> wlan0),
          # which makes the Steam Deck and the rest of the LAN reachable from rack.
          publicKey = "Qd0IGtduY3Jq5jxAqx4s2B4QlWEvGG4ACeGmrM9V2W0=";
          allowedIPs = [ "10.100.0.3/32" "192.168.1.0/24" ];
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
  networking.firewall.allowedUDPPorts = [ 443 ];
}
