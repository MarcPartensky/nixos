# services/cage-firefox/default.nix
# Headless cage session dedicated to VNC: a browser alone, without a desktop.
#
# Second VNC access path, IN ADDITION to the niri + wayvnc setup of
# modules/home/wayvnc. Comparison:
#
#   niri + wayvnc (modules/home/wayvnc)   cage + wayvnc (here)
#   ------------------------------------  ---------------------------------
#   captures the real niri desktop         captures a single app
#   requires vkms (kernel module, virtual output)  wlroots headless backend, nothing to load
#   the virtual output takes a workspace   no effect on the local session
#   dies if the output disappears          independent of the rest
#   starts with the niri session           system service, starts at boot without login
#
# Serves this kind of need: open a graphical browser on tower
# remotely, do a human login (Amazon, bank...), without depending on a
# plugged-in screen nor a locally opened session.
#
# Access:
#   LAN : http://192.168.1.44:6081/vnc.html
#         (6081 open in profiles/tower/configuration.nix)
#   SSH tunnel : ssh -L 6081:localhost:6081 marc@tower then http://localhost:6081/vnc.html
#
# Tuning details, learned on the test bench:
#   - cage starts its own XWayland, so an X11 app works just as well
#     as a native Wayland app.
#   - the wlroots headless output (HEADLESS-1) announces ONLY 1280x720, but
#     accepts any size via --custom-mode. We are at 1920x1080.
#   - the mode must be set BEFORE wayvnc: wayvnc freezes the screen size at
#     its connection and does not re-read it afterwards. Hence the order imposed in the
#     session script and not an ExecStartPost.
#
# Security: websockify listens on 0.0.0.0:6081, so reachable on the LAN without
# its own password (neither noVNC nor wayvnc have one). Do not publish 6081
# beyond the LAN.
{
  pkgs,
  config,
  ...
}: let
  # Size of the virtual screen of this session.
  width = 1920;
  height = 1080;

  # noVNC + wayvnc, same packages as the niri session, in the stable pin.
  novncPort = 6081;
  rfbPort = 5901;

  # Dedicated browser profile: does not touch marc's usual firefox
  # profile (two firefox on the same profile fight over the lock).
  stateDir = "/var/lib/cage-firefox";

  # Session script: cage in the background, we wait for its socket, we set the
  # mode, then wayvnc takes over (exec) to be the process tracked by
  # systemd. wayvnc is on loopback, only websockify sees the LAN.
  session = pkgs.writeShellScript "cage-firefox-session" ''
    set -eu
    export XDG_RUNTIME_DIR=/run/cage-firefox
    export WAYLAND_DISPLAY=wayland-0

    # Firefox requires that the profile folder already exists, otherwise it exits on a
    # "Profile Missing" box instead of creating it. StateDirectory guarantees us
    # /var/lib/cage-firefox under marc's name, the sub-folder remains to be created.
    mkdir -p ${stateDir}/profile

    ${pkgs.cage}/bin/cage -- ${pkgs.firefox}/bin/firefox --no-remote -profile ${stateDir}/profile &
    cage_pid=$!

    # Wait for cage to have published its socket before talking to the compositor.
    for _ in $(seq 1 100); do
      [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break
      sleep 0.1
    done

    # Ignored if the output does not exist yet, the session stays usable at
    # 1280x720 rather than dying.
    ${pkgs.wlr-randr}/bin/wlr-randr --output HEADLESS-1 --custom-mode ${toString width}x${toString height} || true

    exec ${pkgs.wayvnc}/bin/wayvnc -o HEADLESS-1 127.0.0.1 ${toString rfbPort}
  '';
in {
  systemd.services.cage-firefox = {
    description = "Headless cage session + firefox, exposed over VNC";
    # System service and not user: the VNC session must exist even if nobody
    # is connected locally, unlike a user service (marc's
    # Linger is off) and unlike the niri session which requires a
    # graphical login.
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      User = "marc";
      Group = "users";
      WorkingDirectory = stateDir;
      StateDirectory = "cage-firefox"; # creates /var/lib/cage-firefox under marc's name
      RuntimeDirectory = "cage-firefox"; # XDG_RUNTIME_DIR of the session (0700)
      ExecStart = "${session}";
      # Default KillMode = control-group: cage, firefox and wayvnc fall
      # together on restart or stop.
      Restart = "always";
      RestartSec = "3s";
    };
    environment = {
      WLR_BACKENDS = "headless"; # the backend that creates the virtual output
      WLR_LIBINPUT_NO_DEVICES = "1"; # do not grab the physical devices
      MOZ_ENABLE_WAYLAND = "1";
    };
  };

  # Web client: noVNC in HTML + WebSocket bridge to wayvnc's RFB.
  systemd.services.novnc-cage = {
    description = "noVNC (cage/firefox session) on port ${toString novncPort}";
    wantedBy = ["multi-user.target"];
    after = ["cage-firefox.service"];
    requires = ["cage-firefox.service"];
    serviceConfig = {
      # DynamicUser: no state on disk, everything is read from the store.
      DynamicUser = true;
      ExecStart = "${pkgs.python3Packages.websockify}/bin/websockify --file-only --web ${pkgs.novnc}/share/webapps/novnc 0.0.0.0:${toString novncPort} localhost:${toString rfbPort}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  networking.firewall.allowedTCPPorts = [novncPort]; # wayvnc stays on loopback
}
