{ pkgs, config, lib, ... }:

let
  # Création du script exécutable
  autoWallpaper = pkgs.writers.writePython3Bin "auto-wallpaper" {
    libraries = [ pkgs.python3Packages.pyyaml ]; 
    flakeIgnore = [ "E" "W" ]; # Ignore les lignes trop longues (linter)
  } (builtins.readFile ./auto_wallpaper.py); 

  # On définit la configuration ici, de manière centralisée
  wallpaperConfig = {
    pool_size = 10;
    weather_factors = {
      "rain" = 0.7;
      "cloud" = 0.8;
      "overcast" = 0.7;
      "clear" = 1.0;
      "snow" = 0.9;
    };
    swww = {
      transition_type = "fade";
    };
  };
in
{
  # Installation des paquets
  home.packages = with pkgs; [ 
    swww          
    imagemagick   
    curl          
    autoWallpaper # Le script qu'on vient de créer
  ];

  home.file."git/wallpapers/config.yml".text = builtins.toJSON wallpaperConfig;

  # --- 1. Service One-Shot : Le script qui change le wallpaper ---
  systemd.user.services.auto-wallpaper = {
    Unit = {
      Description = "Automated wallpaper changer based on light and weather";
      After = [ "swww-daemon.service" ]; # Doit se lancer APRES le daemon
      Wants = [ "swww-daemon.service" ];
    };
    
    Service = {
      # On ajoute les dépendances au PATH du service
      Path = with pkgs; [ swww imagemagick curl coreutils ];
      ExecStart = "${autoWallpaper}/bin/auto-wallpaper";
      Type = "oneshot";
      IOSchedulingClass = "idle";
    };
    
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  # --- 2. Timer : Lance le script toutes les 30 min ---
  systemd.user.timers.auto-wallpaper = {
    Unit = {
      Description = "Timer for auto-wallpaper";
    };
    Timer = {
      OnBootSec = "2m";        
      OnUnitActiveSec = "30m"; 
      Unit = "auto-wallpaper.service";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # --- 3. Le Daemon SWWW (Doit tourner en permanence) ---
  systemd.user.services.swww-daemon = {
    Unit = {
      Description = "swww wallpaper daemon";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.swww}/bin/swww-daemon";
      Restart = "always";
      RestartSec = 3;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
