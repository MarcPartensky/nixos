{
  config,
  pkgs,
  inputs,
  ...
}: {
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
  networking.hostName = "macos";

  # services.nix-daemon.enable = true;  <- delete this line

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {inherit inputs;};
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
      cleanup = "zap"; # removes packages not listed
      upgrade = true;
    };

    brews = [
      "mas" # homebrew CLI packages
    ];

    casks = [
      "librewolf"
      "rqbit"
    ];

    masApps = {
      # App Store (requires mas)
      "Xcode" = 497799835;
    };
  };

  system.stateVersion = 6;
}
