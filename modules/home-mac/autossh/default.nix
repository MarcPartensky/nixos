# Tunnel SSH inverse permanent Mac -> rack (VPS) : expose le sshd du Mac sur
# 127.0.0.1:2223 du VPS (GatewayPorts no : jamais exposé publiquement).
# Importé par profiles/macos/configuration.nix (module nix-darwin) ; la clé
# du Mac (marc@Air-de-Marc) est déjà autorisée pour root@rack.
# Depuis tower (alias `mac` dans ~/.ssh/config de hermes) :
#   ssh -J rack -p 2223 marc@localhost
# Nécessite Remote Login activé (services.openssh.enable dans le profil).
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
        # Sans ça, un forward raté (port pris, sshd down au boot) laisserait
        # une session inutile ; avec, autossh sort et launchd réessaie.
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
