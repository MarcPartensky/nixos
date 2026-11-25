# Permanent reverse SSH tunnel Mac -> rack (VPS): exposes the Mac's sshd on
# 127.0.0.1:2223 of the VPS (GatewayPorts no: never exposed publicly).
# Imported by profiles/macos/configuration.nix (nix-darwin module); the Mac's
# key (marc@Air-de-Marc) is already authorized for root@rack.
# From tower (alias `mac` in hermes's ~/.ssh/config):
#   ssh -J rack -p 2223 marc@localhost
# Requires Remote Login enabled (services.openssh.enable in the profile).
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
        # Without this, a failed forward (port taken, sshd down at boot) would leave
        # a useless session; with it, autossh exits and launchd retries.
        "-o" "ExitOnForwardFailure=yes"
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
