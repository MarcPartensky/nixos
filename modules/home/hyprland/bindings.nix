{ pkgs, ... }: {
  wayland.windowManager.hyprland.settings = {
    "$mod" = "SUPER";

    bind = [
      # --- Applications & Utilitaires ---
      "$mod, d, exec, wofi --show drun"
      "$mod, return, exec, alacritty"
      "$mod, f, exec, librewolf"
      "$mod, b, exec, gtk-launch blueberry"
      "alt, l, exec, nautilus"
      "alt, w, exec, auto-wallpaper"

      # --- Gestion des Fenêtres ---
      "$mod, c, killactive"
      "$mod, v, togglefloating"
      "$mod, m, fullscreen"
      "$mod, t, togglegroup"
      "supershift, c, exec, xdotool getwindowfocus windowkill"
      "supershift, q, exit,"

      # --- Navigation style VIM (Fenêtres) ---
      "$mod, h, movefocus, l"
      "$mod, l, movefocus, r"
      "$mod, k, movefocus, u"
      "$mod, j, movefocus, d"

      # --- Navigation style VIM (Espaces de travail) ---
      # Navigation relative (Suivant/Précédent)
      "ALT, j, workspace, e+1"
      "ALT, k, workspace, e-1"

      # --- Multimédia & Audio ---
      "alt, d, exec, playerctl -p spotify next"
      "alt, s, exec, playerctl -p spotify previous"
      "alt, k, exec, playerctl -p spotify play-pause"
      ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%+"
      ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%-"
      ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"

      # --- Luminosité ---
      ", XF86MonBrightnessUp, exec, brightnessctl s +1%"
      ", XF86MonBrightnessDown, exec, brightnessctl s 1%-"

      # --- Captures d'écran ---
      ", Print, exec, grimblast copysave area"
      "$mod, Print, exec, grimblast copysave output"

      # --- Presse-papiers ---
      ", Prior, exec, wl-copy"
      ", Next, exec, wl-paste"
    ];

    # --- Souris & Navigation ---
    bindm = [
      "$mod, mouse:272, movewindow"
      "$mod, mouse:273, resizewindow"
    ];

    binde = [
      "$mod, mouse_down, workspace, e+1"
      "$mod, mouse_up, workspace, e-1"
    ];

    # --- Workspaces dynamiques (1 à 9) ---
    # $mod + [1-9] pour changer de workspace
    # $alt + [1-9] pour déplacer la fenêtre vers le workspace
    binds = builtins.concatLists (builtins.genList (i:
      let ws = i + 1;
      in [
        "$mod, code:1${toString i}, workspace, ${toString ws}"
        "ALT, code:1${toString i}, movetoworkspace, ${toString ws}"
      ]
    ) 9);
  };
}
