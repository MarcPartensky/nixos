{ lib, ... }: {
  services.autossh = {
    sessions = [
      {
        name = "rack-tunnel";
        user = "marc";
        # Tunnel SSH inverse : publie le sshd de tower sur 127.0.0.1:2222 du
        # VPS (son sshd est en GatewayPorts no, jamais expose).
        #
        # ExitOnForwardFailure : sans lui, un bind refuse laisse une session
        # ssh VIVANTE mais muette, et le port reste ferme sur le VPS jusqu'au
        # reboot suivant (constate le 24/11/2026 : autossh tournait depuis 2 h,
        # `remote port forwarding failed for listen port 2222`, rack:2222
        # injoignable). ServerAlive* : detection d'une session morte.
        # 127.0.0.1 explicite : on ne demande jamais un bind public par erreur.
        extraArguments = "-N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R 127.0.0.1:2222:localhost:22 root@marcpartensky.com";
      }
    ];
  };

  # Le module amont pose Restart=on-success (systemd ne relance donc jamais une
  # session morte) et AUTOSSH_GATETIME=0 (un echec repete fait tourner autossh
  # en boucle serree). On borne : autossh abandonne apres 30 s, systemd
  # relance 10 s plus tard.
  systemd.services.autossh-rack-tunnel = {
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = lib.mkForce "10s";
    };
    environment.AUTOSSH_GATETIME = lib.mkForce "30";
  };
}
