{ lib, ... }: {
  services.autossh = {
    sessions = [
      {
        name = "rack-tunnel";
        user = "marc";
        # Reverse SSH tunnel: publishes tower's sshd on 127.0.0.1:2222 of the
        # VPS (its sshd is in GatewayPorts no, never exposed).
        #
        # ExitOnForwardFailure: without it, a refused bind leaves a session
        # ssh ALIVE but mute, and the port stays closed on the VPS until the
        # next reboot (observed on 24/11/2026: autossh had been running for 2 h,
        # `remote port forwarding failed for listen port 2222`, rack:2222
        # unreachable). ServerAlive*: detection of a dead session.
        # explicit 127.0.0.1: a public bind is never requested by mistake.
        extraArguments = "-N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R 127.0.0.1:2222:localhost:22 root@marcpartensky.com";
      }
    ];
  };

  # The upstream module sets Restart=on-success (so systemd never restarts a
  # dead session) and AUTOSSH_GATETIME=0 (a repeated failure makes autossh spin
  # in a tight loop). We bound it: autossh gives up after 30 s, systemd
  # restarts 10 s later.
  systemd.services.autossh-rack-tunnel = {
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = lib.mkForce "10s";
    };
    environment.AUTOSSH_GATETIME = lib.mkForce "30";
  };
}
