{
  inputs,
  pkgs,
  ...
}: {
  imports = [
    inputs.nixvim.homeModules.default
    inputs.sops.homeManagerModules.sops
    ../marc/packages.nix

    # CLI, aucun impact sur la session
    ../../modules/home/git
    ../../modules/home/zsh
    ../../modules/home/ssh
    ../../modules/home/starship
    ../../modules/home/neovim
    ../../modules/home/tealdeer
    ../../modules/home/gh
    ../../modules/home/topgrade
    ../../modules/home/rbw
    ../../modules/home/yt-dlp
    ../../modules/home/pgcli
    # ../../modules/home/geminicommit
    ../../modules/home/claude-commit
    ../../modules/home/tewi
    ../../modules/home/ytui-music

    # GUI en simple paquet : utile en Desktop Mode, inerte en Gaming Mode
    ../../modules/home/kitty
    ../../modules/home/alacritty
    ../../modules/home/mpv
    ../../modules/home/zathura
    ../../modules/home/zen-browser
  ];

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  # spécifique deck, n'a rien à faire dans home.nix
  home.file."Desktop/return-to-gaming-mode.desktop" = {
    executable = true;
    text = ''
      [Desktop Entry]
      Name=Return to Gaming Mode
      Exec=steamos-session-select gamescope
      Icon=steam
      Terminal=false
      Type=Application
    '';
  };

  home = {
    username = "marc";
    homeDirectory = "/home/marc";
    stateVersion = "25.11";

    sessionVariables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
    };
  };

  programs.home-manager.enable = true;
}
