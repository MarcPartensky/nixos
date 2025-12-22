{ pkgs, ... }:
let
  # On définit l'utilisateur ici ou via une variable de ton flake
  user = "marc"; 
in
{
  services.greetd = {
    enable = true;
    settings = {
      # Autologin : lance Niri directement au démarrage
      initial_session = {
        # dbus-run-session est la clé pour fixer ton erreur Spotify/D-Bus
        command = "dbus-run-session niri";
        user = "${user}";
      };
      # Session par défaut : ce qui s'affiche si tu te délogues
      default_session = {
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --cmd 'dbus-run-session niri'";
        user = "greeter";
      };
    };
  };

  # Pour que tuigreet puisse fonctionner sans erreur de permissions
  systemd.services.greetd.serviceConfig = {
    Type = "simple";
    StandardInput = "tty";
    StandardOutput = "tty";
    StandardError = "journal"; # Aide pour débugger
    TTYReset = true;
    TTYVHangup = true;
    TTYVTDisallocate = true;
  };

  security.pam.services.greetd.enableGnomeKeyring = true;
}
