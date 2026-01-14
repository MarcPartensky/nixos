{ pkgs, ... }:

{
  services.clipcat = {
    enable = true;

    daemonSettings = {
      # OBLIGATOIRE : false pour que systemd gère le processus sans erreur
      daemonize = false;
      
      max_history = 50;

      # SUPPRIME 'path = null'. 
      # Par défaut, sans chemin spécifié, Clipcat log vers stdout (donc journalctl).
      log = {
        level = "info";
      };
    };

    # Configuration minimale pour le menu
    menuSettings = {
      print_command = "rofi -dmenu -p 'Clipcat'";
    };
  };

  systemd.user.services.clipcat.Service.X-RestartIfChanged = false;

  systemd.user.services.clip-notify = {
    Unit = {
      Description = "Notification copie presse-papier";
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
