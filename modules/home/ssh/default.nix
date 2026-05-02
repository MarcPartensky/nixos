{pkgs, ...}: {
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    # extraConfig = "
    #   Host rack
    #     Hostname marcpartensky.com
    #     Port 42069
    #     User marc
    # ";
    matchBlocks = {
      "rack" = {
        # host = "rack";
        hostname = "marcpartensky.com";
        user = "root";
        port = 22;
        identityFile = "~/.ssh/id_ed25519";
        serverAliveInterval = 60;
        forwardAgent = true;
      };

      "towerlocal" = {
        hostname = "192.168.1.2";
        user = "marc";
        port = 22;
        identityFile = "~/.ssh/id_ed25519";
        serverAliveInterval = 60;
        forwardAgent = true;
      };

      "tower" = {
        hostname = "77.207.176.170";
        user = "marc";
        port = 42070;
        identityFile = "~/.ssh/id_ed25519";
        serverAliveInterval = 60;
        forwardAgent = true;
      };
    };
  };
}
