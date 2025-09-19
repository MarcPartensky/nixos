{ pkgs, ... }:
{

  home-manager.users.marc = { pkgs, inputs, ... }: {
    programs.git = {
      userName = "marc";       # replace with your name
      userEmail = "marc@marcpartensky.com"; # replace with your email
      enable = true;
      # aliases = {
      #   ci = "commit";
      #   co = "checkout";
      #   s = "status";
      # };
    };
  };
}
