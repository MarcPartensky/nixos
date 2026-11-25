{
  config,
  pkgs,
  ...
}:
let
  # Attaches (or creates) a zellij session and records it with asciinema, server-side.
  # The recording lives in the remote process: it therefore survives reconnections AND.
  # Variables: ET_RECORD_DIR (default ~/recordings/et), ET_RECORD_KEEP_DAYS (default 30).
  etSession = pkgs.writeShellApplication {
    name = "et-session";
    runtimeInputs = [
      pkgs.asciinema
      pkgs.zellij
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      if [ "''${1:-}" = "-h" ] || [ "''${1:-}" = "--help" ]; then
        echo "usage: et-session [zellij session]   (default: main)"
        exit 0
      fi

      session="''${1:-main}"
      dir="''${ET_RECORD_DIR:-$HOME/recordings/et}"
      keep="''${ET_RECORD_KEEP_DAYS:-30}"
      mkdir -p "$dir"

      # Rotation: purge the recordings of THIS user older than $keep days
      # (-type f ignores the latest-*.cast symlinks)
      find "$dir" -maxdepth 1 -name '*.cast' -type f -mtime "+$keep" -delete

      stamp="$(date -u +%Y%m%dT%H%M%SZ)"
      cast="$dir/$session-$stamp.cast"
      ln -sfn "$cast" "$dir/latest-$session.cast"
      printf 'et-session: zellij session "%s" on %s, recording -> %s\n' \
        "$session" "$HOSTNAME" "$cast"

      exec asciinema rec --quiet --idle-time-limit 5 \
        --title "et $HOSTNAME $session $stamp" \
        --command "zellij attach --create $session" \
        "$cast"
    '';
  };
in
{
  # Eternal Terminal server configuration
  services.eternal-terminal = {
    enable = true;

    # The default port is 2022, you can change it if needed
    port = 2022;

    # Optional options (uncomment to use):
    # verbosity = 0;
    # silent = false;
    # logSize = 20971520;
  };

  # Session helper (`et-session` = zellij + asciinema recording) and asciinema.
  environment.systemPackages = [
    etSession
    pkgs.asciinema
  ];

  # VERY IMPORTANT: Open the port in the firewall to be able to connect to it
  networking.firewall.allowedTCPPorts = [config.services.eternal-terminal.port];

  # Disables telemetry (crash reports sent to a third party)
  environment.variables.ET_NO_TELEMETRY = "1";
  systemd.services.eternal-terminal.environment.ET_NO_TELEMETRY = "1";

  # Port open only on the Headscale tailnet
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    config.services.eternal-terminal.port
  ];
}
