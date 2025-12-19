{ pkgs, ... }:

{
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        # --time: affiche l'heure
        # --remember: se souvient du dernier utilisateur
        # --cmd: la commande à lancer après connexion (ex: Hyprland, sway, startx)
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --cmd niri";
        user = "greeter";
      };
    };
  };

  # Optionnel : Empêche les messages de boot de polluer l'écran de tuigreet
  boot.kernelParams = [ "console=tty1" ];
}
