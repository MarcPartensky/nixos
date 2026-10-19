{...}: {
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        IdentityFile = "~/.ssh/id_ed25519";
        ServerAliveInterval = 60;
        ForwardAgent = true;
      };
      "rack" = {
        HostName = "marcpartensky.com";
        User = "root";
        Port = 22;
      };
      "towerlocal" = {
        HostName = "192.168.1.44";
        User = "marc";
        Port = 22;
      };
      "hermes" = {
        HostName = "192.168.1.44";
        User = "hermes";
        Port = 22;
      };
      "deck" = {
        HostName = "192.168.1.67";
        User = "hermes";
        Port = 22;
      };
      # tower par le VPN wg1 du VPS (10.100.0.1) : l'ancien forward de la box
      # (77.207.176.170:42070) est mort, l'IP publique change.
      "tower" = {
        HostName = "10.100.0.3";
        User = "marc";
        Port = 22;
      };
      "tunnel" = {
        HostName = "localhost";
        User = "marc";
        Port = 2222;
        ProxyJump = "rack";
      };
    };
  };
}
