{ config, pkgs, inputs, ... }: {
  imports = [
    inputs.home-manager.darwinModules.home-manager
    # inputs.sops.nixosModules.sops  # Inclus dans sopswarden

    # ../../services/wg-quick
  ];

  environment.systemPackages = [
    inputs.nix-darwin.packages.aarch64-darwin.darwin-rebuild
    pkgs.vim
    pkgs.neovim
    pkgs.git
  ];


  nixpkgs.config.allowUnfree = true;

  # services.nix-daemon.enable = true;  <- supprime cette ligne

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    backupFileExtension = "bak";
    users.marc = import ../../users/mac/home.nix;
  };

  # darwin-configuration.nix ou flake.nix -> darwinConfigurations
  system.keyboard = {
    enableKeyMapping = true;
    remapCapsLockToEscape = true;
  };

  system.primaryUser = "marc";

  # deactivated
  homebrew = {
    enable = false;
    onActivation = {
      autoUpdate = true;
      cleanup = "zap";      # supprime les packages non listés
      upgrade = true;
    };

    brews = [
      "mas"                 # packages CLI homebrew
    ];

    casks = [
      "librewolf"
      "rqbit"
      "beeper"
    ];

    masApps = {             # App Store (nécessite mas)
      "Xcode" = 497799835;
    };
  };



  system.stateVersion = 6;
}
