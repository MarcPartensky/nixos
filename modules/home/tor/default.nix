{ pkgs, ... }:
{
  # services.tor = {
  #   enable = true;
  #   openFirewall = true;
  #   relay = {
  #     enable = true;
  #     role = "relay";
  #   };
  #   settings = {
  #     ContactInfo = " z-ophiuchi@proton.me ";
  #     Nickname = "toradmin";
  #     ORPort = 9001;
  #     ControlPort = 9051;
  #     BandWidthRate = "1 MBytes";
  #   };
  # };

  services = {
    tor = {
      enable = true;
      client.dns.enable = true;
      settings= {
        UseBridges = true;
        ClientTransportPlugin = "obfs4 exec ${pkgs.obfs4}/bin/lyrebird";
        Bridge = "obfs4 IP:ORPort [fingerprint]";
        DNSPort = [{
          addr = "127.0.0.1";
          port = 53;
        }];
        TransPort = [ 9040 ];
        DNSPort = 5353;
        VirtualAddrNetworkIPv4 = "172.30.0.0/16";
      };
    };
    resolved = {
      enable = true; # For caching DNS requests.
      fallbackDns = [ "" ]; # Overwrite compiled-in fallback DNS servers.
    };
  };
  networking.nameservers = [ "127.0.0.1" ];
  
  networking = {
    useNetworkd = true;
    bridges."tornet".interfaces = [];
    nftables = {
      enable = true;
      ruleset = ''
        table ip nat {
          chain PREROUTING {
            type nat hook prerouting priority dstnat; policy accept;
            iifname "tornet" meta l4proto tcp dnat to 127.0.0.1:9040
            iifname "tornet" udp dport 53 dnat to 127.0.0.1:5353
          }
        }
      '';
    };
    nat = {
      internalInterfaces = [ "tornet " ];
      forwardPorts = [
        {
          destination = "127.0.0.1:5353";
          proto = "udp";
          sourcePort = 53;
        }
      ];
    };
    firewall = {
      enable = true;
      interfaces.tornet = {
        allowedTCPPorts = [ 9040 ];
        allowedUDPPorts = [ 5353 ];
      };
    };
  };

  systemd.network = {
    enable = true;
    networks.tornet = {
      matchConfig.Name = "tornet";
      DHCP = "no";
      networkConfig = {
        ConfigureWithoutCarrier = true;
        Address = "10.100.100.1/24";
      };
      linkConfig.ActivationPolicy = "always-up";
    };
  };
  
  boot.kernel.sysctl = {
    "net.ipv4.conf.tornet.route_localnet" = 1;
  };


}
