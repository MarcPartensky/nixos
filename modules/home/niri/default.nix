{ pkgs, lib, ... }:
let
  # --- CONFIGURATION SCREENSHOTS ---
  screenshotDir = "~/media/screenshots";
  # Format : Année-Mois-Jour_Heure-Min-Sec (ex: 2024-05-20_14-30-05)
  screenshotFormat = "$(date +%Y-%m-%d_%H-%M-%S).png";
in
{
  # Assure-toi que niri et alacritty sont installés
  home.packages = [
    pkgs.alacritty
    pkgs.niri
    pkgs.xwayland-satellite
  ];

  systemd.user.sessionVariables = {
    DISPLAY = ":0";
    NIXOS_OZONE_WL = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "wayland";
    GDK_BACKEND = "wayland";
    QT_QPA_PLATFORM = "wayland";
    XDG_CURRENT_DESKTOP = "niri";
    XDG_SESSION_TYPE = "wayland";
  };

  xdg.portal = {
    enable = true;
    config.common.default = "*";
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk # fallback UI
      xdg-desktop-portal-gnome
    ];
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
    };
  };


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
    GTK_IS_WIDGET = 0;
  };

  programs.niri = {
    package = pkgs.niri;
    # package = inputs.niri.packages.${pkgs.system}.niri-stable;
    settings = {
      outputs = {
        "eDP-1" = {
          mode = {
            width = 1920;
            height = 1080;
            refresh = 60.027;
          };
          position = { x = 0; y = 0; };
        };

        "DP-1" = {
          mode = {
            width = 2560;
            height = 1440;
            refresh = 59.951;
          };
          position = { x = -320; y = -1440; };
        };
      };
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

      binds = {

        # --- Navigation Vim ---
        # Colonnes (Gauche / Droite)
        "Mod+H".action.focus-column-left = [ ];
        "Mod+L".action.focus-column-right = [ ];
        
        # Workspaces (Suivant / Precedent)
        "Mod+J".action.focus-workspace-down = [ ];
        "Mod+K".action.focus-workspace-up = [ ];

        # --- Navigation existante ---
        "Mod+Q".action.close-window = [ ];
        "Mod+Left".action.focus-column-left = [ ];
        "Mod+Right".action.focus-column-right = [ ];
        "Mod+Up".action.focus-window-or-monitor-up = [ ];
        "Mod+Down".action.focus-window-or-monitor-down = [ ];
        "Mod+Shift+E".action.quit = [ ];

        # --- Applications ---
        "Mod+D".action.spawn = [ "wofi" "--show" "drun" ];
        "Mod+Return".action.spawn = "alacritty";
        "Mod+F".action.spawn = "librewolf";
        "Mod+B".action.spawn = [ "gtk-launch" "blueberry" ];
        "Alt+L".action.spawn = "nautilus";

        # --- Gestion des fenêtres ---
        "Mod+M".action.maximize-column = [ ];
        "Mod+V".action.toggle-window-floating = [ ];
        "Mod+C".action.close-window = [ ];
        "Super+Shift+C".action.close-window = [ ];
        "Super+Shift+Q".action.quit.skip-confirmation = true;

        # PRINT : Direct -> Dossier + Presse-papier (Automatique)
        "Print".action.spawn = [ 
          "sh" "-c" 
          "grim -g \"$(slurp)\" - | tee ${screenshotDir}/${screenshotFormat} | wl-copy" 
        ];

        # MOD + PRINT : Edit -> Satty (Interactif)
        # Satty permet de choisir ensuite de sauver ou copier via son interface
        "Mod+Print".action.spawn = [ 
          "sh" "-c" 
          "grim -g \"$(slurp)\" - | satty -f - --output-filename ${screenshotDir}/${screenshotFormat}" 
        ];


        # --- Multimedia ---
        "Prior".action.spawn = "wl-copy";
        "Next".action.spawn = "wl-paste";
        "Alt+D".action.spawn = [ "playerctl" "-p" "spotify" "next" ];
        "Alt+S".action.spawn = [ "playerctl" "-p" "spotify" "previous" ];
        "Alt+K".action.spawn = [ "playerctl" "-p" "spotify" "play-pause" ];
        "Alt+W".action.spawn = [ "auto-wallpaper" ];

        # --- Materiel ---
        "XF86AudioRaiseVolume".action.spawn = [ "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "1%+" ];
        "XF86AudioLowerVolume".action.spawn = [ "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "1%-" ];
        "XF86AudioMute".action.spawn = [ "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle" ];
        "XF86MonBrightnessUp".action.spawn = [ "brightnessctl" "s" "+1%" ];
        "XF86MonBrightnessDown".action.spawn = [ "brightnessctl" "s" "1%-" ];

      } // lib.attrsets.mergeAttrsList (map (i:
         let
          ws = toString i;
        in {
          "Alt+${ws}".action.move-window-to-workspace = i;
          "Mod+${ws}".action.focus-workspace = i;
        }
      ) [ 1 2 3 4 5 6 7 8 9 ]);

      # Lancement automatique
      spawn-at-startup = [
        { argv = [ "${pkgs.xdg-desktop-portal}/libexec/xdg-desktop-portal" ]; }
        { argv = [ "dbus-update-activation-environment" "--systemd" "all" ]; }
        { argv = [ "systemctl" "--user" "import-environment" "PATH" "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP" ]; }
        { argv = [ "xwayland-satellite" ":" ]; }

        { argv = [ "alacritty" ]; }
        { argv = [ "zen" ]; }
        { argv = [ "spotify" ]; }
      ];

      overview.zoom = 0.2;
      input.mouse.natural-scroll = true;
      input.focus-follows-mouse.enable = true;

      outputs = {
        "eDP-1" = {
          enable = true;
          scale = 1;
        };
      };

      # Quelques réglages visuels pour ne pas être perdu
      layout = {
        default-column-width = {
          proportion = 0.5;
        };
        border.enable = false;
        focus-ring.enable = false;
        shadow.enable = true;
      };

      window-rules = [
        # Alacritty -> Workspace 1
        {
          matches = [{ app-id = "Alacritty"; }];
          open-on-workspace = "1";
        }
        # Zen Browser -> Workspace 2
        {
          matches = [{ app-id = "^zen"; }]; # Regex pour matcher zen ou zen-alpha
          open-on-workspace = "2";
        }
        # Spotify -> Workspace 3
        {
          matches = [{ app-id = "Spotify"; }]; # Spotify utilise souvent XWayland
          open-on-workspace = "3";
        }
        {
          # Pour toutes les fenêtres qui n'ont PAS le focus
          matches = [{ is-active = false; }];
          
          # On réduit l'ombre (plus petite, plus transparente)
          shadow = {
            enable = true;
            softness = 10;
            spread = 2;
            color = "#00000044"; # Ombre très discrète
          };
        }
      ];
    };
  };
}
