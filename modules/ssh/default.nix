{ pkgs, ... }:
{
  programs.ssh = {
    enable = true;
    forwardAgent = true;
    serverAliveInterval = 60;
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
      };
    };
  };
}
