{ pkgs, ... }:

let
  user = "marc";
  # On crée un script de lancement propre
  niri-session = pkgs.writeShellScriptBin "niri-session" ''
    # 1. On exporte les variables cruciales vers le bus systemd
    # Cela permet à Spotify de "voir" le bus D-Bus déjà lancé par NixOS
    dbus-update-activation-environment --systemd --all
    
    # 2. On lance Niri
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

  # Optionnel mais recommandé : débloquer le keyring GNOME sans mot de passe à l'autologin
  security.pam.services.greetd.enableGnomeKeyring = true;
}
