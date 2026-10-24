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

    # Tunnel SSH inverse Mac -> rack (launchd agent) : expose le sshd du Mac
    # sur 127.0.0.1:2223 du VPS, pour que tower (ou marc) joigne le Mac hors
    # LAN. La clé du Mac est déjà autorisée pour root@rack.
    ../../modules/home-mac/autossh
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

  # --- Nix : flakes et utilisateurs de confiance -------------------------
  # Le Mac build Winnie par `nix develop` (voir modules/home-mac/winnie) : les
  # flakes doivent être actives dans /etc/nix/nix.conf, pas seulement passées en
  # ligne de commande, et marc doit être trusted-user pour que le client puisse
  # charger des substituts ou surcharger une option locale.
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@admin"];
  };

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

  # --- SSH entrant : Remote Login + clés -----------------------------------
  # Active sshd (com.openssh.sshd) : nix-darwin écrit sshd_config.d et fait
  # `launchctl enable + bootstrap` à l'activation (pas de systemsetup, qui
  # exige Full Disk Access). La clé hermes@tower est posée dans
  # /Users/marc/.ssh/authorized_keys par users/mac/home.nix (home.activation).
  # Reachabilité : LAN direct (tower et le Mac sont sur 192.168.1.0/24) ;
  # hors LAN via le tunnel inverse autossh (modules/home-mac/autossh) que
  # tower joint par `ssh -J rack -p 2223 marc@localhost`.
  services.openssh.enable = true;

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

  # --- Xcode : installation manuelle, reste automatique -------------------
  # Apple interdit la redistribution du SDK : Xcode vient de l'App Store (aucun
  # paquet nix ne peut le fournir). Tout ce qui suit l'installation est en
  # revanche scriptable, et c'est ici : developer dir, licence, premiers
  # composants. Le runtime du simulateur (~8 Go) n'est pas téléchargé
  # silencieusement : `winnie-doctor --fix` s'en charge à la demande.
  system.activationScripts.winnie-xcode.text = ''
    if [ -d /Applications/Xcode.app ]; then
      if [ "$(/usr/bin/xcode-select -p 2>/dev/null || true)" != "/Applications/Xcode.app/Contents/Developer" ]; then
        echo "winnie : xcode-select -> /Applications/Xcode.app" >&2
        /usr/bin/xcode-select -s /Applications/Xcode.app || true
        /usr/bin/xcodebuild -license accept || true
        /usr/bin/xcodebuild -runFirstLaunch || true
      fi
    else
      echo "winnie : Xcode absent (App Store) ; le build macOS marche sans, seul winnie-ios l'exige" >&2
    fi
  '';

  # --- sudo pour l'agent : opérations root du toolchain Xcode -------------
  # hermes@tower se connecte en ssh (marc@mac) et pilote les rares opérations
  # root de Xcode : bascule de xcode-select, acceptation de la licence,
  # téléchargement du runtime du simulateur. Fragment sudoers.d séparé (pas
  # security.sudo.extraConfig, déjà posé par le bloc terminfo de nix-darwin).
  # Limité aux trois shims : le reste du sudo de marc exige son mot de passe.
  environment.etc."sudoers.d/20-hermes-xcode".text = ''
    marc ALL=(root) NOPASSWD: /usr/bin/xcode-select, /usr/bin/xcodebuild, /usr/bin/xcrun
  '';

  system.stateVersion = 6;
}
