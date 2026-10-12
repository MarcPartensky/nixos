{
  config,
  pkgs,
  lib,
  ...
}: {
  # --- herdr : config de marc posee par le systeme ---
  # herdr (multiplexeur d'agents) n'a pas d'option NixOS ; sa config vit dans
  # ~/.config/herdr/config.toml et sert a afficher le MODELE hermes de chaque
  # pane dans la sidebar (cf modules/nixos/herdr/config.toml).
  #
  # Marc est en home-manager STANDALONE (users/marc/home.nix, `HM=marc just home`,
  # que hermes n'active pas) : on pose donc le fichier cote systeme, sous forme de
  # symlink vers le store, exactement ce que ferait xdg.configFile. Un `just nixos`
  # suffit, sans attendre une generation home-manager.
  # (Le module home-manager `programs.herdr` n'existe pas dans le home-manager
  # epingle : xdg.configFile serait la seule alternative, meme mecanisme.)
  #
  # Effet a chaud : `herdr server reload-config` (ou relance du client). Le fichier
  # est en lecture seule (store) : une edition manuelle de ~/.config/herdr/config.toml
  # ne tient pas, c'est ce fichier-ci qui fait foi.
  systemd.tmpfiles.rules = [
    "d /home/marc/.config/herdr 0755 marc users -"
    "L+ /home/marc/.config/herdr/config.toml - - - - ${./config.toml}"
  ];
}
