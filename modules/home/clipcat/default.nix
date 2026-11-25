{ pkgs, ... }:

{
  services.clipcat = {
    enable = true;

    daemonSettings = {
      # MANDATORY: false so systemd manages the process without error
      daemonize = false;
      max_history = 50;

      # REMOVE 'path = null'. 
      # By default, with no path specified, Clipcat logs to stdout (so journalctl).
      log = {
        level = "info";
      };
    };

    # Minimal configuration for the menu
    menuSettings = {
      print_command = "rofi -dmenu -p 'Clipcat'";
    };
  };

  systemd.user.services.clipcat.Service.X-RestartIfChanged = false;

  systemd.user.services.clip-notify = {
    Unit = {
      Description = "Clipboard copy notification";
      After = [ "graphical-session.target" ];
    };

    Install = {
      WantedBy = [ "graphical-session.target" ];
    };

    Service = {
      ExecStart = toString (
        pkgs.writeShellScript "clip-notify-script" ''
          ${pkgs.wl-clipboard}/bin/wl-paste --watch \
          ${pkgs.libnotify}/bin/notify-send "📋 Copy" -t 1500 -u low
        ''
      );
      Restart = "always";
      X-RestartIfChanged = false;
    };
  };
}
