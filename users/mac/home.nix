{
  pkgs,
  inputs,
  config,
  lib,
  ...
}: {
  imports = [
    inputs.sops.homeManagerModules.sops
    inputs.typer.homeManagerModules.default

    ../../modules/home/claude-commit
    ../../modules/home/ssh
    ../../modules/home/eternal-terminal
    ../../modules/home/zsh
    ../../modules/home/alacritty
    ../../modules/home/kitty
    ../../modules/home/starship
    ../../modules/home/yt-dlp
    ../../modules/home/syncthing
    ../../modules/home/pgcli
    ../../modules/home/python
    # ../../modules/home/librewolf

    ../../modules/home-mac/aerospace
    ../../modules/home-mac/paneru
    ../../modules/home-mac/hermes-desktop-plugins
    ../../modules/home-mac/hermes-skins
    ../../modules/home-mac/winnie
    # ../../modules/home-mac/autossh
  ];

  home.username = "marc";
  home.homeDirectory = pkgs.lib.mkForce (
    if pkgs.stdenv.isDarwin
    then "/Users/marc"
    else "/home/marc"
  );
  home.stateVersion = "25.11";
  home.packages = with pkgs; [
    fzf
    gemini-cli
    geminicommit
    tree
    eza
    bat
    gnupg
    # claude-code
    # black
    ncdu
    nix-du
    util-linux
    sops
    typer
    # typer-race : client terminal des salons de typer.marcpartensky.com,
    # depuis le flake typer (projects/typer) ; ttyper reste l'exercice solo.
    (pkgs.callPackage (inputs.typer.outPath + "/package.nix") {})
    ttyper # version TUI de typer.macpartensky.com (exercice de frappe)
    nerd-fonts.meslo-lg # MesloLGS NF
    nmap
    just
    age
    speedtest-go
    gh
    uv

    # neovim deps manquants
    ripgrep # telescope live-grep + vim.health
    fd # telescope extended
    stylua # conform lua formatter
    prettier # conform prettier
    tree-sitter # lspsaga + nvim-treesitter CLI
    sox # gp.nvim audio
    pngpaste # img-clip (macOS)
    findutils # GNU find (fix fzf-lua "illegal option")
    luarocks # lazy.nvim rocks

    neovim-node-client # node provider

    # (nerdfonts.override { fonts = [ "Meslo" ]; })
    # ou sur nixpkgs récent :
    nerd-fonts.meslo-lg
    meslo-lg
    meslo-lgs-nf
    fastfetch
    htop
    nodejs

    upscayl
    upscayl-ncnn
    realesrgan-ncnn-vulkan
    imagemagick
    wireguard-tools
    iproute2mac
  ];

  programs.typer-race = {
    enable = true;
    url = "ws://100.64.0.4:9146/ws";  # laptop mesh IP
    name = "marc";
    lang = "english200";
    time = 30;
    ui = "en";
  };

  # nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
  #   "claude-code"
  # ];

  home.sessionVariables = {
    SOPS_AGE_KEY_FILE = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
  };

  # sops.age.keyFile = "/Users/marc/.config/sops/age/keys.txt";
  sops.age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
  sops.defaultSopsFile = ../../secrets/mac.yml;

  services.gpg-agent = {
    enable = true;
    pinentry.package = pkgs.pinentry-curses;
  };

  programs.home-manager = {
    enable = true;
    # backupFileExtension = "backup";
    # backupCommand',
  };

  programs.git = {
    enable = true;
    settings.user.name = "Marc Partensky";
    settings.user.email = "marc.partensky@gmail.com";
  };

  programs.zsh.enable = true;

  # Skins Hermes (pack Hermes Menagerie) -> ~/.hermes/skins/
  my.hermesSkins.enable = true;


  # Plugin desktop « Claude Code Theme » : surfaces plates, bulles grises
  # alignées à droite, composer et panneaux en cartes arrondies (le look Claude),
  # avec l'accent remplacé par le mauve Catppuccin : #8839ef (Latte, mode clair)
  # et #cba6f7 (Mocha, mode sombre).
  #
  # Source épinglée sur la révision du catalogue Hermes (la même que
  # `hermes plugins install aliilhami/hermes-claude-code-theme`) : elle ne bouge
  # pas au `nix flake update`, rev + hash s'éditent ensemble.
  #
  # Une seule retouche, en --replace-fail (une mise à jour du plugin qui change
  # cette ligne casse le build au lieu de rendre un réglage fantôme) : l'accent
  # par défaut, parce que le réglage du plugin vit dans le localStorage du
  # renderer et n'est donc pas pré-remplissable depuis Nix.
  #
  # Plus la barre latérale, un cran plus sombre que le reste : le thème aplatit
  # tout sur --ccl-bg, on définit --ccl-sidebar par mode et on la branche sur
  # --ui-sidebar-surface-background. Teinte = celle de l'accent (mauve), très
  # légère, comme les thèmes Catppuccin qui teintent leurs surfaces avec la
  # couleur du flavor : #1a191e en sombre, #f4f2f6 en clair. Pas de gris bleuté
  # (mantle Mocha #181825 essayé et rejeté : trop bleu).
  # ATTENTION : cette variable
  # est partagée avec la barre d'état et le bandeau de titre d'un volet
  # (tree-group.tsx), donc les trois deviennent un seul aplat, et le
  # bandeau de la zone de chat reste sur la base : la marche est voulue, c'est
  # elle qui dessine la colonne de gauche. Ne PAS reteinter cette variable avec
  # l'accent mauve : ça produit une couture sale au milieu de la barre du haut.
  my.hermesDesktopPlugins = {
    enable = true;
    plugins.claude-code-theme = pkgs.runCommand "hermes-claude-code-theme-plugin.js" { } ''
      cp ${pkgs.fetchFromGitHub {
        owner = "aliilhami";
        repo = "hermes-claude-code-theme";
        rev = "d2430687cde455e470f5f75b951e488eb0938e61";
        hash = "sha256-o9MAH3sM6BwqgjROLzrLkxNoZ2lkX36D40ZNNVaDBwM=";
      }}/desktop/plugin.js $out

      substituteInPlace $out --replace-fail \
        "const DEFAULTS = { accentEnabled: false, accentLight: '#2d2d2b', accentDark: '#e7e7e7' }" \
        "const DEFAULTS = { accentEnabled: true, accentLight: '#8839ef', accentDark: '#cba6f7' }"

      substituteInPlace $out --replace-fail \
        "  --ccl-bg: #fbfbf9; --ccl-card: #ffffff; --ccl-subtle: #f7f7f6; --ccl-hover: #f3f3f2;" \
        "  --ccl-bg: #fbfbf9; --ccl-card: #ffffff; --ccl-subtle: #f7f7f6; --ccl-hover: #f3f3f2; --ccl-sidebar: #f4f2f6;"

      substituteInPlace $out --replace-fail \
        "  --ccl-bg: #151515; --ccl-card: #1e1e1e; --ccl-subtle: #232323; --ccl-hover: #2a2a2a;" \
        "  --ccl-bg: #151515; --ccl-card: #1e1e1e; --ccl-subtle: #232323; --ccl-hover: #2a2a2a; --ccl-sidebar: #1a191e;"

      substituteInPlace $out --replace-fail \
        "  --ui-sidebar-surface-background: var(--ccl-bg) !important;" \
        "  --ui-sidebar-surface-background: var(--ccl-sidebar) !important;"

      # Bulles de messages et champs de saisie sur le même aplat que la barre de
      # gauche : marc veut moins de gris différents dans l'interface. --ccl-bubble
      # porte ses propres bulles, --ccl-card le composer (et, tant qu'à faire,
      # les menus déroulants et les cartes du panneau fichiers, qui étaient à un
      # quatrième gris).
      substituteInPlace $out --replace-fail \
        "  --ccl-bubble: #f1f1f0; --ccl-row-active: #eeedeb; --ccl-row-open: #f4f3f1;" \
        "  --ccl-bubble: var(--ccl-sidebar); --ccl-row-active: #eeedeb; --ccl-row-open: #f4f3f1;"

      substituteInPlace $out --replace-fail \
        "  --ccl-bubble: #262626; --ccl-row-active: #303030; --ccl-row-open: #242424;" \
        "  --ccl-bubble: var(--ccl-sidebar); --ccl-row-active: #303030; --ccl-row-open: #242424;"

      substituteInPlace $out --replace-fail \
        "  --composer-fill: var(--ccl-card) !important;" \
        "  --composer-fill: var(--ccl-sidebar) !important;"

      substituteInPlace $out --replace-fail \
        "  background: var(--ccl-card) !important;" \
        "  background: var(--ccl-sidebar) !important;"
    '';
  };

  # Build de l'app Winnie sur le Mac : winnie-doctor, winnie-sync, winnie-ios,
  # winnie-macos, winnie-front, winnie-verify. Le toolchain reste dans le
  # devShell du flake `winnie`, ces commandes ne font que l'appeler.
  my.winnie.enable = true;

  # Connexions Eternal Terminal vers les hôtes NixOS : `et tower` = zellij enregistré.
  my.et = {
    enable = true;
    hosts = {
      tower = {};
      towerlocal = {};
    };
  };

  # Clés SSH autorisées sur marc@mac :
  #   - hermes@tower, pour que l'agent (qui tourne sur tower) entre en marc@ ;
  #   - marc@Air-de-Marc, la clé ed25519 du Mac lui-même, pour que marc puisse
  #     s'y connecter depuis une autre machine du tailnet (ssh marc@100.64.0.5)
  #     et pour que l'alias `mac` réponde depuis le Mac.
  # Append idempotent plutôt que home.file.".ssh/authorized_keys" : ne remplace
  # JAMAIS un authorized_keys déjà en place (le .bak de home-manager perdrait
  # les clés existantes).
  home.activation.addHermesAuthorizedKey = lib.hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    for key in \
      'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower' \
      'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdX5m7b8xWL/9ZUeFRxahB4YY0v2rAV5CCFv8xTOlUh marc@Air-de-Marc'; do
      grep -qxF "$key" "$HOME/.ssh/authorized_keys" || echo "$key" >> "$HOME/.ssh/authorized_keys"
    done
    chmod 600 "$HOME/.ssh/authorized_keys"
  '';

  # SSH: no override here any more. The shared module (modules/home/ssh) points
  # every tailnet alias (tower, deck, laptop, mac, phone, vps) at its mesh
  # address, which works from any network without the rack ProxyJump. The
  # former tower=10.100.0.3 (wg1 via rack, ~85 KB/s) and deck=192.168.1.67
  # (LAN-only) overrides were removed on 2026-11-24.
}
