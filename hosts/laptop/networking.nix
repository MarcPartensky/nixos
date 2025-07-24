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
    nameservers = [ "8.8.8.8" "8.8.4.4" ];
    enableIPv6 = false;

    # nat = {
    #   enable = true;
    #   internalInterfaces = ["ve-+"];
    #   externalInterface = "enp0s31f6"; # eth interface
    # };

    networkmanager.enable = true; # enable network manager to start during boot
    networkmanager.wifi.backend = "iwd";
    # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

    wireless.networks = {
        "AP25G".psk = secrets.wifi-ap25g-vaugneray;
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
