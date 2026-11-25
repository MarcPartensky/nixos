{ pkgs, ... }:
{

  programs.topgrade = {
    enable = true;
    settings = {
      misc = {
        assume_yes = false; # do not validate automatically
        set_title = false;  # do not change the terminal title
        cleanup = true;     # run cleanup after update
        disable = [
          "home_manager" # if you want to manage Home Manager yourself
        ];
      };
      commands = {
        "Run garbage collection on Nix store" = "nix-collect-garbage";
      };
    };
  };

}
