{ pkgs, ... }:
{
  programs.git = {
    enable = true;
    # aliases = {
    #   ci = "commit";
    #   co = "checkout";
    #   s = "status";
    # };
  };
}
