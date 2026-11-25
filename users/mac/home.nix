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
    # typer-race: terminal client for the rooms of typer.marcpartensky.com,
    # from the typer flake (projects/typer); ttyper remains the solo exercise.
    (pkgs.callPackage (inputs.typer.outPath + "/package.nix") {})
    ttyper # TUI version of typer.macpartensky.com (typing exercise)
    nerd-fonts.meslo-lg # MesloLGS NF
    nmap
    just
    age
    speedtest-go
    gh
    uv

    # missing neovim deps
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
    # or on recent nixpkgs:
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


  # Desktop plugin "Claude Code Theme": flat surfaces, grey bubbles
  # right-aligned, composer and panels as rounded cards (the Claude look),
  # with the accent replaced by the Catppuccin mauve: #8839ef (Latte, light mode)
  # and #cba6f7 (Mocha, dark mode).
  #
  # Source pinned to the Hermes catalog revision (the same as
  # `hermes plugins install aliilhami/hermes-claude-code-theme`): it does not move
  # on `nix flake update`, rev + hash are edited together.
  #
  # A single touch-up, in --replace-fail (a plugin update that changes
  # this line breaks the build instead of leaving a ghost setting): the default
  # accent, because the plugin setting lives in the renderer's
  # localStorage and so cannot be pre-filled from Nix.
  #
  # Plus the sidebar, one notch darker than the rest: the theme flattens
  # everything onto --ccl-bg, we define --ccl-sidebar per mode and wire it to
  # --ui-sidebar-surface-background. Hue = that of the accent (mauve), very
  # light, like the Catppuccin themes that tint their surfaces with the
  # flavor color: #1a191e in dark, #f4f2f6 in light. No bluish grey
  # (mantle Mocha #181825 tried and rejected: too blue).
  # WARNING: this variable
  # is shared with the status bar and the title bar of a pane
  # (tree-group.tsx), so the three become a single flat surface, and the
  # chat area banner stays on the base: the step is intended, it is
  # what draws the left column. Do NOT re-tint this variable with
  # the mauve accent: it produces an ugly seam in the middle of the top bar.
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

      # Message bubbles and input fields on the same flat surface as the left
      # bar: marc wants fewer different greys in the interface. --ccl-bubble
      # carries its own bubbles, --ccl-card the composer (and, while at it,
      # the dropdown menus and the cards of the files panel, which were at a
      # fourth grey).
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

  # Build of the Winnie app on the Mac: winnie-doctor, winnie-sync, winnie-ios,
  # winnie-macos, winnie-front, winnie-verify. The toolchain stays in the
  # devShell of the `winnie` flake, these commands only call it.
  my.winnie.enable = true;

  # Eternal Terminal connections to the NixOS hosts: `et tower` = recorded zellij.
  my.et = {
    enable = true;
    hosts = {
      tower = {};
      towerlocal = {};
    };
  };

  # SSH keys authorized on marc@mac:
  #   - hermes@tower, so the agent (running on tower) can enter marc@ ;
  #   - marc@Air-de-Marc, the Mac's own ed25519 key, so marc can
  #     connect to it from another tailnet machine (ssh marc@100.64.0.5)
  #     and so the `mac` alias answers from the Mac.
  # Idempotent append rather than home.file.".ssh/authorized_keys": NEVER
  # replaces an authorized_keys already in place (the home-manager .bak would lose
  # the existing keys).
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
