{
  config,
  pkgs,
  inputs,
  ...
}: let
  # Client VPN Pangolin pour macOS : extrait du .dmg officiel (fosrl/apple).
  # Mise à jour : bump version + hash (`nix store prefetch-file --json <url>`).
  pangolin-client = pkgs.stdenvNoCC.mkDerivation {
    pname = "pangolin-client";
    version = "0.12.1";
    src = pkgs.fetchurl {
      url = "https://github.com/fosrl/apple/releases/download/mac-0.12.1/Pangolin_Installer_0.12.1.dmg";
      hash = "sha256-RETTcY6f6kqsyNrEKOToyPq/GAHu1ujY6pjzcKevgEA=";
    };
    nativeBuildInputs = [pkgs.undmg];
    sourceRoot = ".";
    unpackPhase = "undmg $src";
    installPhase = ''
      mkdir -p $out/Applications
      cp -R *.app $out/Applications/
    '';
    meta = {
      description = "Pangolin client (zero-trust VPN) pour macOS";
      homepage = "https://pangolin.net";
      platforms = pkgs.lib.platforms.darwin;
    };
  };
in {
  imports = [
    inputs.home-manager.darwinModules.home-manager

    # Réseau privé ygg-mesh sur macOS (daemon yggdrasil + client tor) :
    # voir services/ygg-mesh/darwin.nix ; /etc/yggdrasil.conf à créer une fois.
    ../../services/ygg-mesh/darwin.nix


    # inputs.sops.nixosModules.sops  # Inclus dans sopswarden

    # ../../services/wg-quick
  ];

  environment.systemPackages = [
    inputs.nix-darwin.packages.aarch64-darwin.darwin-rebuild
    pkgs.vim
    pkgs.neovim
    pkgs.git
    pkgs.eternal-terminal
  ];

  nixpkgs.config.allowUnfree = true;
  networking.hostName = "macos";

  # services.nix-daemon.enable = true;  <- supprime cette ligne

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
      cleanup = "zap"; # supprime les packages non listés
      upgrade = true;
    };

    brews = [
      "mas" # packages CLI homebrew
    ];

    casks = [
      "librewolf"
      "rqbit"
      "beeper"
    ];

    masApps = {
      # App Store (nécessite mas)
      "Xcode" = 497799835;
    };
  };

  # Copie l'app dans /Applications à chaque activation : une app avec
  # extension réseau ne doit pas tourner depuis un symlink du store Nix.
  system.activationScripts.pangolin-client.text = ''
    rm -rf /Applications/Pangolin.app
    cp -R ${pangolin-client}/Applications/Pangolin.app /Applications/
  '';

  system.stateVersion = 6;
}
