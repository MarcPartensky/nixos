{ pkgs, ... }:
{

  programs.topgrade = {
    enable = true;
    settings = {
      misc = {
        assume_yes = false; # ne pas valider automatiquement
        set_title = false;  # ne pas changer le titre du terminal
        cleanup = true;     # exécuter le nettoyage après mise à jour
        disable = [
          "home_manager" # si tu veux gérer Home Manager toi-même
        ];
      };
      commands = {
        "Run garbage collection on Nix store" = "nix-collect-garbage";
      };
    };
  };

}
