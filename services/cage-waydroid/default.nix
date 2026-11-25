# services/cage-waydroid/default.nix
# Waydroid (Android LineageOS) in a HEADLESS cage compositor, exposed over VNC
# standard (wayvnc) on the LAN, protected by a password. Pattern of
# services/cage-firefox.
#
# WHY root (no User=): `waydroid session start` calls
# waydroid-net.sh which creates the waydroid0 bridge (CAP_NET_ADMIN). As non-root it
# exits with "Operation not permitted". Moreover the waydroid session is a
# GLOBAL SINGLETON (a 2nd session, even from another user, exits with
# "Already tracking a session"): this service is the one that holds it.
#
# WHY headless cage (and not weston): waydroid requires a Wayland compositor.
# In headless there is NO host compositor constraint (no X11, no
# 32-bit visual): cage is enough. Isolated and robust mode.
#
# PREREQUISITE (once, root): `sudo waydroid init -s GAPPS` (images).
#
# ACCESS (LAN only):
#   Finder > Go > Connect to Server... > vnc://192.168.1.44:5902
#   (or `vncviewer 192.168.1.44:5902` with TigerVNC / RealVNC Viewer)
#   password: android
#   DES auth (VncAuth) -> macOS Screen Sharing works.
{ pkgs, ... }:
let
  # Portrait, phone format.
  width = 1080;
  height = 1920;

  rfbPort = 5902;
  # Loopback port of the noVNC bridge (target of the newt/Pangolin connector). NOT opened
  # to the LAN: only newt reaches it, and it runs on tower (127.0.0.1).
  novncPort = 6082;
  # Simple password (DES = 8 chars max, the rest is ignored), LAN
  # only. To move it out of the Nix store, put it in secrets/ (sops).
  vncPassword = "android";

  # cage in the background with the Waydroid UI, then wayvnc becomes the process
  # tracked by systemd (like cage-firefox).
  session = pkgs.writeShellScript "cage-waydroid-session" ''
    set -eu
    export XDG_RUNTIME_DIR=/run/cage-waydroid
    export HOME=/var/lib/cage-waydroid
    export WAYLAND_DISPLAY=wayland-0
    export WLR_BACKENDS=headless
    export WLR_LIBINPUT_NO_DEVICES=1

    # waydroid generates in config_session lxc.mount.entry WITHOUT 'optional'
    # for the pulse socket and the data folder: if these paths do not exist,
    # LXC refuses to start the container ("container failed to start").
    # We provide a real UNIX socket that accepts then closes (audio is not
    # routed, but the mount is valid and does not block boot).
    mkdir -p "$XDG_RUNTIME_DIR/pulse"
    ${pkgs.python3}/bin/python3 -c '
import os, socket, sys
p = sys.argv[1]
try:
    os.unlink(p)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX)
s.bind(p)
s.listen(16)
while True:
    try:
        c, _ = s.accept()
        c.close()
    except OSError:
        pass
' "$XDG_RUNTIME_DIR/pulse/native" &
    mkdir -p "$HOME/.local/share/waydroid/data"

    # `waydroid show-full-ui` starts the session if needed then opens the full-screen
    # UI, which cage displays.
    ${pkgs.cage}/bin/cage -- ${pkgs.waydroid}/bin/waydroid show-full-ui &
    cage_pid=$!

    # Wait for the compositor socket before talking to the output.
    for _ in $(seq 1 150); do
      [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break
      sleep 0.2
    done

    # The wlroots headless output only advertises 1280x720: we force portrait.
    ${pkgs.wlr-randr}/bin/wlr-randr --output HEADLESS-1 --custom-mode ${toString width}x${toString height} || true

    # wayvnc: DES auth (classic VncAuth, type 2). It is the ONLY mode that
    # macOS Screen Sharing can negotiate (wayvnc README: "This option exists
    # solely for compatibility with VNC clients that support DES but do not
    # support the absence of authentication, such as macOS Screen Sharing").
    # relax_encryption + allow_broken_crypto = no encryption (password
    # DES in clear): acceptable on the LAN, NOT beyond. Listens on all
    # interfaces, the firewall acts as the LAN filter.
    vdir="$HOME/wayvnc"
    mkdir -p "$vdir"
    cat > "$vdir/config" <<EOF
address=0.0.0.0
port=${toString rfbPort}
enable_auth=true
password=${vncPassword}
relax_encryption=true
allow_broken_crypto=true
EOF

    exec ${pkgs.wayvnc}/bin/wayvnc -C "$vdir/config"
  '';
in {
  systemd.services.cage-waydroid = {
    description = "Waydroid (Android) in headless cage, exposed over VNC (LAN, password)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "waydroid-container.service" ];
    requires = [ "waydroid-container.service" ];
    serviceConfig = {
      # Deliberate ROOT: waydroid-net.sh needs CAP_NET_ADMIN.
      RuntimeDirectory = "cage-waydroid";
      StateDirectory = "cage-waydroid"; # /var/lib/cage-waydroid = persistent HOME
      # The waydroid session is a GLOBAL singleton on the container side: when this
      # service is restarted alone (switch, crash), the container keeps
      # "Session: RUNNING" without a client and `waydroid show-full-ui` exits with
      # "RuntimeError: Already tracking a session" on each attempt, so
      # the service loops (observed 20/11/2026: 400 failures in 2 h, ~0.12 core and
      # a `waydroid.log` of 850 KB). We free the orphan session BEFORE
      # starting: this service is the sole owner, so this stop cannot
      # cut off a useful session.
      ExecStartPre = "-${pkgs.waydroid}/bin/waydroid session stop";
      # Bound on the number of attempts: without it, Restart=always hides a
      # failure behind an infinite loop (the systemd default of 5 starts
      # in 10 s is never reached with RestartSec=5s).
      StartLimitIntervalSec = 300;
      StartLimitBurst = 6;
      ExecStart = "${session}";
      # Default KillMode = control-group: cage, waydroid and wayvnc go down
      # together on restart.
      Restart = "always";
      RestartSec = "5s";
    };
    # HOME required by wayvnc ("Failed to load config. Success" without it) and
    # so that the wayvnc keys + the waydroid data folder persist.
    environment.HOME = "/var/lib/cage-waydroid";
  };

  # noVNC web client: WebSocket -> RFB bridge of wayvnc, on loopback.
  # Target of the newt connector (Pangolin): nothing is opened to the LAN by this port.
  # noVNC handles the VncAuth(DES) auth of wayvnc itself (it asks for the
  # password), so the websockify bridge stays in clear (no --ssl-target).
  systemd.services.novnc-waydroid = {
    description = "noVNC (WebSocket -> wayvnc:${toString rfbPort} bridge) for Pangolin";
    wantedBy = [ "multi-user.target" ];
    after = [ "cage-waydroid.service" ];
    requires = [ "cage-waydroid.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3Packages.websockify}/bin/websockify --file-only --web ${pkgs.novnc}/share/webapps/novnc 127.0.0.1:${toString novncPort} localhost:${toString rfbPort}";
      Restart = "always";
      RestartSec = "5s";
    };
  };

  networking.firewall.allowedTCPPorts = [ rfbPort ];
}