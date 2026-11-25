# services/hinge-auto/default.nix
# Auto-like Hinge web (app.hinge.co) via Playwright + Chromium, following the
# exact pattern of services/amazon-mcp: persistent chromium profile in
# /var/lib/hermes/hinge-auto/user-data, marc ACL for the visible manual login.
#
# Two binaries installed in the system profile:
#   hinge-auto-login     VISIBLE chromium, to launch from a graphical session
#                        of marc (wayvnc/kasm): phone + SMS, Enter = save.
#                        A single login lasts until the session expires.
#   hinge-auto-like      headless like loop on Discover (HINGE_HEADLESS=0
#                        to see what the browser does). Safeguards:
#                        HINGE_MAX_LIKES (default 40) + end-of-feed detection.
#   hinge-auto-calibrate dump of the buttons to refine the selectors.
#
# NB: the persistent profile does NOT support two chromium instances at the same
# time (lock): do not launch login while a like is running.
#
# Hinge free limit: ~8 likes/day (Hinge+/X = unlimited). The script stops
# on the end marker, not on a fixed count.
{ pkgs, ... }:
let
  python = pkgs.python312;
  py = python.pkgs;

  script = pkgs.writeText "hinge_auto.py" (builtins.readFile ./hinge_auto.py);

  playwrightPython = python.withPackages (ps: [ ps.playwright ]);
in {
  # Helpers available for marc (visible login) and for a server run (like).
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "hinge-auto-login";
      runtimeInputs = [ playwrightPython ];
      text = ''
        export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
        exec python3 ${script} login
      '';
    })
    (pkgs.writeShellApplication {
      name = "hinge-auto-like";
      runtimeInputs = [ playwrightPython ];
      text = ''
        export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
        export HINGE_HEADLESS="''${HINGE_HEADLESS:-1}"
        exec python3 ${script} like
      '';
    })
    (pkgs.writeShellApplication {
      name = "hinge-auto-calibrate";
      runtimeInputs = [ playwrightPython ];
      text = ''
        export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
        exec python3 ${script} calibrate
      '';
    })
  ];

  # Persistent profile shared hermes <-> marc (login). amazon-mcp pattern:
  # /var/lib/hermes in 2770 hermes:hermes, marc needs the traversal --x.
  systemd.tmpfiles.rules = [
    "a /var/lib/hermes - - - - u:marc:--x,m::rwx"
    "d /var/lib/hermes/hinge-auto 0750 hermes hermes - -"
    "a /var/lib/hermes/hinge-auto - - - - u:marc:rwx,d:u:marc:rwx,d:u:hermes:rwx,m::rwx,d:m::rwx"
  ];
}