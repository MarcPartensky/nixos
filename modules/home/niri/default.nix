{ pkgs, ... }:
{
  # Assure-toi que niri et alacritty sont installés
  home.packages = [
    pkgs.alacritty
    pkgs.niri
  ];

  # 1. FIX D-BUS : Permet à dconf de s'activer sans erreur
  # dconf.settings = {
    # On force une config vide ou minimale si nécessaire pour éviter l'erreur "address is empty"
  # };

  # On s'assure que les services dbus utilisateur sont là
  #services.dbus.enable = true;
  home.sessionVariables = {
    # Force Electron/Chromium à utiliser Wayland
    NIXOS_OZONE_WL = "1";
    # Indique aux applis Qt d'utiliser wayland
    QT_QPA_PLATFORM = "wayland";
    # Indique aux applis SDL d'utiliser wayland
    SDL_VIDEODRIVER = "wayland";
    # Pour Mozilla (si besoin)
    MOZ_ENABLE_WAYLAND = "1";
    # Variables XDG standards
    XDG_SESSION_TYPE = "wayland";
    XDG_CURRENT_DESKTOP = "niri";
  };

  programs.niri = {
    package = pkgs.niri;
    # package = inputs.niri.packages.${pkgs.system}.niri-stable;
    settings = {
      # Configuration du clavier (important pour un utilisateur FR)
      input.keyboard.xkb = {
        layout = "fr";
        variant = "us"; # "us" pour avoir le layout qwerty mais typé FR
      };

      input = {
        mod-key = "Super";
        # mod-key-nested = "Alt";
        mod-key-nested = "Super";
      };

      # Les raccourcis clavier
      binds = {
        # Fermer la fenêtre active
        "Mod+Q".action.close-window = [ ];

        # Navigation horizontale (Le cœur de Niri)
        "Mod+Left".action.focus-column-left = [ ];
        "Mod+Right".action.focus-column-right = [ ];
        
        # Navigation entre les fenêtres dans une colonne
        "Mod+Up".action.focus-window-or-monitor-up = [ ];
        "Mod+Down".action.focus-window-or-monitor-down = [ ];

        # Quitter Niri
        "Mod+Shift+E".action.quit = [ ];

        # --- Applications ---
        "Mod+D".action.spawn = [ "wofi" "--show" "drun" ];
        "Mod+Return".action.spawn = "alacritty";
        "Mod+F".action.spawn = "librewolf";
        "Mod+B".action.spawn = [ "gtk-launch" "blueberry" ];
        "Alt+L".action.spawn = "nautilus";

        # --- Gestion des fenêtres ---
        "Mod+M".action.maximize-column = [ ]; # Équivalent fullscreen/maximise
        "Mod+V".action.toggle-window-floating = [ ];
        "Mod+C".action.close-window = [ ];
        "Super+Shift+C".action.close-window = [ ]; # Doublon pour ton xdotool kill
        "Super+Shift+Q".action.quit.skip-confirmation = true;

        # --- Screenshot (Grimblast & Satty) ---
        "Print".action.spawn = [ "sh" "-c" "grim -g \"$(slurp)\" - | satty -f -" ];
        # Alternative grimblast d'après ta conf
        # "Print".action.spawn = [ "grimblast" "copysave" "area" ];
        "Mod+Print".action.spawn = [ "grimblast" "copysave" "output" ];

        # --- Presse-papier & Multimédia ---
        "Prior".action.spawn = "wl-copy";
        "Next".action.spawn = "wl-paste";
        
        "Alt+D".action.spawn = [ "playerctl" "-p" "spotify" "next" ];
        "Alt+S".action.spawn = [ "playerctl" "-p" "spotify" "previous" ];
        "Alt+K".action.spawn = [ "playerctl" "-p" "spotify" "play-pause" ];
        "Alt+W".action.spawn = [ "systemctl" "--user" "restart" "wpaperd" ];

        # --- Contrôles Matériels (Audio/Luminosité) ---
        "XF86AudioRaiseVolume".action.spawn = [ "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "1%+" ];
        "XF86AudioLowerVolume".action.spawn = [ "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "1%-" ];
        "XF86AudioMute".action.spawn = [ "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle" ];

        "XF86MonBrightnessUp".action.spawn = [ "brightnessctl" "s" "+1%" ];
        "XF86MonBrightnessDown".action.spawn = [ "brightnessctl" "s" "1%-" ];

        # --- Souris ---
        # Note : Niri gère le déplacement/redimensionnement à la souris via des réglages dédiés
        # mais on peut binder les clics si nécessaire.
      };

      # Lancement automatique
      spawn-at-startup = [
        { argv = [ "alacritty" ]; } # Ouvre un terminal au démarrage
        { argv = [ "dbus-update-activation-environment" "--systemd" "DISPLAY" "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP" "NIXOS_OZONE_WL" ]; }
      ];

      overview.zoom = 0.2;
      input.mouse.natural-scroll = true;

      outputs = {
        "eDP-1" = {
          enable = true;
          scale = 0.8;
        };
      };

      # Quelques réglages visuels pour ne pas être perdu
      layout = {
        default-column-width = {
          proportion = 0.25;
        };
        border = {
          enable = true;
          width = 5;
        };

        focus-ring = {
          enable = true;
        };
        shadow.enable = true;
      };
    };
  };
}
