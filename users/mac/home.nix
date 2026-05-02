{ pkgs, inputs, config, lib, ... }: {

  imports = [
    inputs.sops.homeManagerModules.sops

    ../../modules/home/claude-commit
    ../../modules/home/ssh
    ../../modules/home/zsh
    ../../modules/home/alacritty
    ../../modules/home/starship
    ../../modules/home/yt-dlp
    ../../modules/home/syncthing
    ../../modules/home/pgcli
    # ../../modules/home/librewolf

    ../../modules/home-mac/aerospace
    # ../../modules/home-mac/autossh

  ];

  home.username = "marc";
  home.homeDirectory = pkgs.lib.mkForce (if pkgs.stdenv.isDarwin then "/Users/marc" else "/home/marc");
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
    black
    ncdu
    nix-du
    util-linux
    sops
    typer
    nerd-fonts.meslo-lg   # MesloLGS NF
    nmap
    just
    age


    # neovim deps manquants
    ripgrep          # telescope live-grep + vim.health
    fd               # telescope extended
    stylua           # conform lua formatter
    nodePackages.prettier  # conform prettier
    tree-sitter      # lspsaga + nvim-treesitter CLI
    sox              # gp.nvim audio
    pngpaste         # img-clip (macOS)
    findutils        # GNU find (fix fzf-lua "illegal option")
    luarocks         # lazy.nvim rocks

    # neovim providers
    (python3.withPackages (ps: [ ps.pynvim ]))
    nodePackages.neovim   # node provider
  ];

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

  programs.home-manager ={
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

}
