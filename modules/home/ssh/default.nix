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
        HostName = "192.168.1.2";
        User = "marc";
        Port = 22;
      };
      "tower" = {
        HostName = "77.207.176.170";
        User = "marc";
        Port = 42070;
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
