{ pkgs, ... }:

let
  shellAliases = import ./aliases.nix;
in
{
  home.packages = with pkgs; [
    zsh-powerlevel10k
    mcfly
    nixd
  ];

  programs.zsh = {
    enable = true;
    enableCompletion = true;

    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    shellAliases = shellAliases;

    plugins = [
      {
        name = "enhancd";
        file = "init.sh";
        src = pkgs.fetchFromGitHub {
          owner = "b4b4r07";
          repo = "enhancd";
          rev = "v2.2.1";
          sha256 = "0iqa9j09fwm6nj5rpip87x3hnvbbz9w9ajgm6wkrd5fls8fn8i5g";
        };
      }

      {
        name = "powerlevel10k";
        src = pkgs.zsh-powerlevel10k;
        file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
      }

      {
        name = "powerlevel10k-config";
        src = ./p10k.zsh;
        file = "p10k.zsh";
      }
    ];

    initExtra = ''
      # McFly
      eval "$(mcfly init zsh)"
      export MCFLY_FUZZY=true
      export MCFLY_RESULTS=50

      # Chargement du thème P10K
      [[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
    '';
  };

  home.file.".p10k.zsh".source = ./p10k.zsh;
}

