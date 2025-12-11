{ pkgs, ... }:
{
  programs.git = {
    delta.enable = true;
    userName = "marc";
    userEmail = "marc@marcpartensky.com";
    enable = true;
    # aliases = {
    #   ci = "commit";
    #   co = "checkout";
    #   s = "status";
    # };
  };
}
