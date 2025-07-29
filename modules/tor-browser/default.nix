{ pkgs } : {
  containers.browser = {
    autoStart = false;
    privateNetwork = true;
    hostAddress = "192.168.7.10";
    localAddress = "192.168.7.11";
    config = {config, pkgs, ... }: {
      services.openssh = {
        enable = true;
        forwardX11 = true;
      };
  
      users.extraUsers.browser = {
        isNormalUser = true;
        home = "/home/browser";
        openssh.authorizedKeys.keys = [ SSH-KEYS-GO-HERE ];
        extraGroups = ["audio" "video"];
      };
    };
  };
  
  # Open necessary ports
  networking.firewall.allowedTCPPorts = [ 4713 6000 ];
  hardware.pulseaudio = {
    enable = true;
    systemWide = true;
    support32Bit = true;
    tcp = { enable = true; anonymousClients = { allowedIpRanges = ["127.0.0.1" "192.168.7.0/24"]; }; };
  };
  
  # Configuring NAT
  networking.nat.enable = true;
  networking.nat.internalInterfaces = ["ve-browser"];
  networking.nat.externalInterface = "YOUR-EXTERNAL-INTERFACE";
  
  # Depending on your use of global or home configuration, you will have to install "socat"
  environment.systemPackages = [
    pkgs.socat
  ];
  
  
}
