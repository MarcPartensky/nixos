{ config, pkgs, inputs, ... }: {
  imports = [
    inputs.home-manager.darwinModules.home-manager
  ];

  environment.systemPackages = [
    inputs.nix-darwin.packages.aarch64-darwin.darwin-rebuild
    pkgs.vim
    pkgs.neovim
    pkgs.git
  ];

  # services.nix-daemon.enable = true;  <- supprime cette ligne

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    backupFileExtension = "bak";
    users.marc = import ../../users/mac/home.nix;
  };

  system.stateVersion = 6;
}
