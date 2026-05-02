# profiles/macos/configuration.nix ou un module dédié
{ pkgs, ... }: {
  environment.systemPackages = [ pkgs.autossh ];

  launchd.user.agents.rack-tunnel = {
    serviceConfig = {
      ProgramArguments = [
        "${pkgs.autossh}/bin/autossh"
        "-M" "0"
        "-N"
        "-o" "ServerAliveInterval=30"
        "-o" "ServerAliveCountMax=3"
        "-R" "2223:localhost:22"
        "root@marcpartensky.com"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "/tmp/autossh-rack-tunnel.log";
      StandardErrorPath = "/tmp/autossh-rack-tunnel.err";
    };
  };
}
