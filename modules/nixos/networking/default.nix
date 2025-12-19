{ pkgs, lib, secrets, ... }: {
  
  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  # networking.interfaces.enp0s20f0u4u4c2.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp4s0.useDHCP = lib.mkDefault true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;


  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  networking = {
    useDHCP = lib.mkDefault true;
    hostName = "nixos";
    hostId = "c1ae84e2";
    nameservers = [ "8.8.8.8" "8.8.4.4" ];
    enableIPv6 = false;

    # nat = {
    #   enable = true;
    #   internalInterfaces = ["ve-+"];
    #   externalInterface = "enp0s31f6"; # eth interface
    # };

    # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

    networkmanager = {
      enable = true;
      wifi.backend = "iwd";
      ensureProfiles.profiles = {
        wifi-de-marc = {
          connection = {
            id = "Wifi de Marc";
            uuid = "73d1cf32-c497-4fd1-ace3-3e12008ecec0";
            type = "wifi";
            autoconnect = true;
            interface-name = "wlan0";
          };
          wifi = {
            mode = "infrastructure";
            ssid = "Wifi de Marc";
          };
          wifi-security = {
            key-mgmt = "wpa-psk";
            psk = "2ipt98gyqf4pud63jeqi";
          };
          ipv4 = {
            method = "auto";
          };
          ipv6 = {
            addr-gen-mode = "default";
            method = "auto";
          };
        };
      };
    };

    wireless.networks = {
        "AP25G".psk = secrets.wifi-ap25g-vaugneray;
        "HKT".psk = secrets.wifi-hkt;
    };

    wireless.iwd = {
      enable = true;
      settings = {
        IPv6 = {
          Enabled = true;
        };
        Settings = {
          AutoConnect = true;
        };
      };
    };
  };

  services.gnome.gnome-keyring.enable = true;
}
