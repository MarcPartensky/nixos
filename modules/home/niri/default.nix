{ pkgs, ... }:
{
  # Assure-toi que niri et alacritty sont installés
  home.packages = [
    pkgs.alacritty
    pkgs.niri
  ];

  # 1. FIX D-BUS : Permet à dconf de s'activer sans erreur
  dconf.settings = {
    # On force une config vide ou minimale si nécessaire pour éviter l'erreur "address is empty"
  };

  # On s'assure que les services dbus utilisateur sont là
  #services.dbus.enable = true;

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
        # Ouvrir Alacritty (L'équivalent de bind = $mainMod, T, exec, alacritty)
        "Mod+T".action.spawn = [ "alacritty" ];

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

        "XF86AudioRaiseVolume".action.spawn = ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1+"];
        "XF86AudioLowerVolume".action.spawn = ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1-"];
      };

      # Lancement automatique
      spawn-at-startup = [
        { argv = [ "alacritty" ]; } # Ouvre un terminal au démarrage
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
