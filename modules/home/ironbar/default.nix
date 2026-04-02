{ pkgs, ... }: {
  home.packages = [ pkgs.ironbar pkgs.wttrbar ];

  xdg.configFile."ironbar/config.toml".source = ./config.toml;
  xdg.configFile."ironbar/style.css".source = ./style.css;

  systemd.user.services.ironbar = {
    Unit = {
      Description = "Ironbar status bar";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.ironbar}/bin/ironbar";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
