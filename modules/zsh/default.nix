{ pkgs, ... }:
{

  environment.systemPackages = with pkgs; [
    # "thefuck"
    zsh-powerlevel10k
  ];

  programs.zsh = {
    enable = true;
    # enableCompletions = true;
    autosuggestions.enable = true;
    # enableAutosuggestions = true;
    syntaxHighlighting.enable = true;
  
    shellAliases = {
      ll = "ls -l";
      v = "nvim";
      update = "sudo nixos-rebuild switch";
    };
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
  };

  home-manager.users.marc = { pkgs, inputs, ... }: {

    programs.zsh = {
      enable = true;
      # enableCompletions = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
    
      shellAliases = {
        ll = "ls -l";
        v = "nvim";
        update = "sudo nixos-rebuild switch";
      };
      # history.size = 10000;

      plugins = [
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
        [[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
      '';

    };
    home.file.".p10k.zsh".source = ./p10k.zsh;  # Chemin personnalisé
  };
}
