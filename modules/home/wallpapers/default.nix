{
  pkgs,
  config,
  lib,
  ...
}: let
  autoWallpaper = pkgs.writers.writePython3Bin "auto-wallpaper" {
    libraries = [pkgs.python3Packages.pyyaml];
    flakeIgnore = ["E" "W"];
  } (builtins.readFile ./auto_wallpaper.py);

  wallpaperConfig = {
    pool_size = 10;
    weather_factors = {
      "rain" = 0.7;
      "cloud" = 0.8;
      "overcast" = 0.7;
      "clear" = 1.0;
      "snow" = 0.9;
    };
    awww = {
      transition_type = "fade";
    };
  };
in {
  home.packages = with pkgs; [
    awww
    imagemagick
    curl
    autoWallpaper
  ];

  home.file."git/wallpapers/config.yml".text = builtins.toJSON wallpaperConfig;

  systemd.user.services.auto-wallpaper = {
    Unit = {
      Description = "Automated wallpaper changer based on light and weather";
      After = ["awww-daemon.service"];
      Wants = ["awww-daemon.service"];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Environment = with pkgs; ["PATH=${awww}/bin:${imagemagick}/bin:${curl}/bin:${coreutils}/bin"];
      ExecStart = "${autoWallpaper}/bin/auto-wallpaper";
      Type = "oneshot";
      IOSchedulingClass = "idle";
      X-RestartIfChanged = false;
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };

  systemd.user.timers.auto-wallpaper = {
    Unit = {
      Description = "Timer for auto-wallpaper";
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Timer = {
      OnBootSec = "2m";
      OnUnitActiveSec = "30m";
      Unit = "auto-wallpaper.service";
    };
    Install = {
      WantedBy = ["timers.target"];
    };
  };

  systemd.user.services.awww-daemon = {
    Unit = {
      Description = "awww wallpaper daemon";
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = "${pkgs.awww}/bin/awww-daemon";
      Restart = "always";
      RestartSec = 3;
      X-RestartIfChanged = false;
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };
}
