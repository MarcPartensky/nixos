{ pkgs, ... }:

let
  shellAliases = import ./aliases.nix;
in
{
  environment.etc."powerlevel10k/p10k.zsh".source = ./p10k.zsh;

  environment.systemPackages = with pkgs; [
    zsh-powerlevel10k
    mcfly
    nixd
    tmux
  ];

  programs.zsh = {
    enable = true;
    enableCompletion = true;

    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;

    shellAliases = shellAliases;
    setOptions = [
      "AUTO_CD"
    ];

    ohMyZsh = {
      enable = true;
      plugins = [
        "git"
        "gh"
        "sudo"
        "rsync"
        "ssh"
        "ssh-agent"
        "systemd"
        "tmux"
        "vi-mode"
        "history"
        "dirhistory"
      ];
    };

   shellInit = ''
      # Sourcing powerlevel10k theme
      source ${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme
      source /etc/powerlevel10k/p10k.zsh

      eval "$(mcfly init zsh)"
      export MCFLY_FUZZY=true
      export MCFLY_RESULTS=50
    '';
  };
}

