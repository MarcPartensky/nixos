{ pkgs, ... }:

{
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        # --time: shows the time
        # --remember: remembers the last user
        # --cmd: the command to launch after login (e.g. Hyprland, sway, startx)
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --cmd niri";
        user = "greeter";
      };
    };
  };

  # Optional: Prevents boot messages from polluting tuigreet's screen
  boot.kernelParams = [ "console=tty1" ];
}
