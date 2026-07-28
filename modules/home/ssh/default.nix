{pkgs, ...}: {
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      "*" = {
        identityFile = "~/.ssh/id_ed25519";
        serverAliveInterval = 60;
        forwardAgent = true;
      };
      "rack" = {
        hostname = "marcpartensky.com";
        user = "root";
        port = 22;
      };
      "towerlocal" = {
        hostname = "192.168.1.2";
        user = "marc";
        port = 22;
      };
      "tower" = {
        hostname = "77.207.176.170";
        user = "marc";
        port = 42070;
      };
      "tunnel" = {
        hostname = "localhost";
        user = "marc";
        port = 2222;
        proxyJump = "rack";
      };
    };
  };
}
