{ pkgs, ... }:

let
  user = "marc";
  # We create a clean launch script
  niri-session = pkgs.writeShellScriptBin "niri-session" ''
    # 1. We export the crucial variables to the systemd bus
    # This lets Spotify "see" the D-Bus bus already started by NixOS
    dbus-update-activation-environment --systemd --all
    
    # 2. We start Niri
    exec niri
  '';
in
{
  services.greetd = {
    enable = true;
    settings = {
      initial_session = {
        command = "${niri-session}/bin/niri-session";
        user = "${user}";
      };
      default_session = {
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --cmd niri";
        user = "greeter";
      };
    };
  };

  # Optional but recommended: unlock the GNOME keyring without a password on autologin
  security.pam.services.greetd.enableGnomeKeyring = true;
}
