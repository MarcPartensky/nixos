{ pkgs, ... }:
let
  aliases = import ./aliases.nix;
  shellAliases = aliases.shellAliases;
  shellAbbrs = aliases.shellAbbrs;
in {

  environment.systemPackages = with pkgs; [
    # "thefuck"
    zsh-powerlevel10k
    mcfly
    nixd
  ];
  # programs.mcfly.enable = true;
  # programs.mcfly.enableZshIntegration = true;

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestions.enable = true;
    # enableAutosuggestions = true;
    syntaxHighlighting.enable = true;
  
    inherit shellAliases;
    # history.size = 10000;

    ohMyZsh = { # "ohMyZsh" without Home Manager
      enable = true;
      plugins = [
       "git"
       # "thefuck"
        # { name = "git"; }
        # { name = "thefuck"; }
        # { name = "zsh-users/zsh-autosuggestions"; } # Simple plugin installation
        # { name = "romkatv/powerlevel10k"; tags = [ as:theme depth:1 ]; } # Installations with additional options. For the list of options, please refer to Zplug README.
      ];
      # theme = "robbyrussell";
    };

    

    # plugins = [
    #   {
    #     name = "powerlevel10k";
    #     src = pkgs.zsh-powerlevel10k;
    #     file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
    #   }
    #   {
    #     name = "powerlevel10k-config";
    #     src = ./p10k.zsh;
    #     file = "p10k.zsh";
    #   }
    # ];

    interactiveShellInit = ''
      # # Instant Prompt
      # if [[ -r "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh" ]]; then
      #   source "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh"
      # fi

      # Initialise McFly
      eval "$(mcfly init zsh)"
      
      # Configuration McFly (optionnel)
      export MCFLY_FUZZY=true  # Activer la recherche floue
      export MCFLY_RESULTS=50   # Nombre de résultats à afficher

      [[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
    '';
    # home.file.".p10k.zsh".source = ./p10k.zsh;  # chemin personnalisé

  };

  home-manager.users.marc = { pkgs, inputs, ... }: {
    # home.packages = with pkgs; [
    #   zsh-powerlevel10k
    #   zsh-enhancd
    # ];

    programs.zsh = {
      inherit shellAliases;
      enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
    
      # history.size = 10000;

      plugins = [
        # {
        #   name = "enhancd";
        #   src = pkgs.zsh-enhancd.src;
        #   file = "init.sh";
        # }
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

      # oh-my-zsh = { # "ohMyZsh" without Home Manager
      #   enable = true;
      #   plugins = [
      #    "git"
      #    # "thefuck"
      #    "history"
      #    "dirhistory"
      #     # { name = "git"; }
      #     # { name = "thefuck"; }
      #     # { name = "zsh-users/zsh-autosuggestions"; } # Simple plugin installation
      #     "powerlevel10k"
      #     # {
      #     #   name = "powerlevel10k";
      #     #   src = pkgs.zsh-powerlevel10k;
      #     #   file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
      #     # }
      #   ];
      #   theme = "powerlevel10k";
      # };

      initContent = ''
        # # Instant Prompt
        # if [[ -r "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh" ]]; then
        #   source "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh"
        # fi

        # Initialise McFly
        eval "$(mcfly init zsh)"
        
        # Configuration McFly (optionnel)
        export MCFLY_FUZZY=true  # Activer la recherche floue
        export MCFLY_RESULTS=50   # Nombre de résultats à afficher

        [[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
      '';

    };
    home.file.".p10k.zsh".source = ./p10k.zsh;  # chemin personnalisé
  };
}
