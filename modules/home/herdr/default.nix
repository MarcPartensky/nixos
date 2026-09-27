{
  config,
  lib,
  ...
}: {
  # --- herdr : config de marc, posee par home-manager ---
  # herdr (multiplexeur d'agents, github:ogulcancelik/herdr) n'a pas d'option
  # NixOS et le module `programs.herdr` n'existe pas encore dans le
  # home-manager epingle (verifie : pas de modules/programs/herdr.nix dans
  # l'input), donc le fichier est declare ici et pose par xdg.configFile.
  #
  # Contenu : voir modules/home/herdr/config.toml (rows de sidebar qui
  # affichent le modele hermes de chaque pane, via le titre OSC ecrit par le
  # TUI ; cote hermes, cela suppose display.interface = "tui", cf
  # services/hermes/default.nix).
  #
  # Application a chaud apres un switch : `herdr server reload-config`
  # (ou menu global -> reload config). Un client deja lance garde son ancienne
  # config jusqu'au reload.
  # `force = true` : la 1re activation du HM systeme bute sinon sur l'ancien
  # symlink /home/marc/.config/herdr/config.toml laisse par la version
  # systemd.tmpfiles (il ne ressemble pas a un fichier home-manager-files, donc
  # check-link-targets le declare "would be clobbered" et l'activation echoue
  # en status=1). force saute ce controle et remplace le lien.
  xdg.configFile."herdr/config.toml" = {
    force = true;
    text = builtins.readFile ./config.toml;
  };
}
