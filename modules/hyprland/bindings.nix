{ pkgs, ... }: {
  home-manager.users.marc = { pkgs, inputs, ... }: {
    wayland.windowManager.hyprland.settings = {
      bind =
        [
          "$mod, d, exec, wofi --show drun"
          ", Print, exec, grimblast copy area"
          "$mod, v, togglefloating"
          "$mod, m, fullscreen"
          "$mod, c, killactive"
          "alt, w, exec, systemctl restart --user wpaperd"
          "supershift, c, exec, xdotool getwindowfocus windowkill"
          "supershift, q, exit,"
          "super,t,togglegroup,"

          "$mod, return, exec, alacritty"
          "$mod, f, exec, librewolf"
          "$mod, b, exec, gtk-launch blueberry"

          "$mod, mouse:272, movewindow"
          "$mod, mouse:273, movewindow"
          # "$mod, mouse:273, resizewindow"
          # "$mod alt, mouse:272, resizewindow"
          # "$mod, mouse:273, resizewindow"

          "$mod,mouse_down,workspace,e+1"
          "$mod,mouse_up,workspace,e-1"

          ",XF86AudioRaiseVolume,exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%+"
          ",XF86AudioLowerVolume,exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%-"
          ",XF86AudioMute,exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"

          ",XF86MonBrightnessUp,exec,brightnessctl s +1%"
          ",XF86MonBrightnessDown,exec,brightnessctl s 1%-"

          ", Print, exec, grimblast copysave area"
          "$mod, Print, exec, grimblast copysave output"

          "SUPER+SHIFT,h,hy3:makegroup, h"
          "SUPER+SHIFT,v,hy3:makegroup, v"
        ]
        ++ (
          # workspaces
          # binds $mod + [shift +] {1..9} to [move to] workspace {1..9}
          builtins.concatLists (builtins.genList (i:
              let ws = i + 1;
              in [
                "$mod, code:1${toString i}, workspace, ${toString ws}"
                "$alt, code:1${toString i}, movetoworkspace, ${toString ws}"
              ]
            )
            9)
        );
    };
  };
}
