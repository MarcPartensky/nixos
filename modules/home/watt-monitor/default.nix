{
  config,
  pkgs,
  lib,
  ...
}: let
  # On crée la recette de compilation Rust
  watt-monitor = pkgs.rustPlatform.buildRustPackage rec {
    pname = "watt-monitor";
    version = "main";

    src = pkgs.fetchFromGitHub {
      owner = "jookwang-park";
      repo = "watt-monitor-rs";
      rev = "main";
      # Les faux hashs à remplacer lors des deux premiers plantages
      hash = "sha256-4xK3v7OvP4eybKraH4mrANlDLNrB1N75g8xkGPeffm8=";
    };

    cargoHash = "sha256-6WAsvlJ4NcOyWBTbcFeMFLLbG5RqBd5wMu6s1GyglBI=";
  };
in {
  # Ajoute l'outil compilé aux paquets de ton utilisateur
  home.packages = [watt-monitor];

  # Déclare le service en tâche de fond (Syntaxe propre à Home Manager)
  systemd.user.services.watt-monitor = {
    Unit = {
      Description = "Watt Monitor Background Daemon";
    };
    Service = {
      # On pointe directement vers le binaire compilé dans le store Nix
      ExecStart = "${pkgs.bash}/bin/sh -c '${watt-monitor}/bin/watt-monitor daemon || ${watt-monitor}/bin/watt-monitor'";
      Restart = "always";
    };
    Install = {
      WantedBy = ["default.target"];
    };
  };
}
