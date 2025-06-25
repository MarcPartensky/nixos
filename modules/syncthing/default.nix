{ inputs, pkgs, ... }: {

  # imports = [
  #   # ./plugins.nix
  # ];

  # home-manager.users.marc = { pkgs, inputs, ... }: {
  #   programs.waybar = {
  #     enable = true;
  #     package = inputs.hyprland.packages.${pkgs.system}.waybar-hyprland
  #   };
  # };
  services = {
    # Syncthing
    syncthing = {
      enable = true;
      user = "marc";
      group = "users";
      dataDir = "/home/marc";
      configDir = "/home/marc/syncthing";
      guiAddress = "127.0.0.1:8384";
      openDefaultPorts = true;
    };
  };
}
