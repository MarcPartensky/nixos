{ pkgs, lib, ... }: {
  
  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  # networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp0s20f0u4u4c2.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp4s0.useDHCP = lib.mkDefault true;

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

}
