{ pkgs, ... }:
{
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
  };
  programs.git = {
    enable = true;
    settings = {
      user.name = "marc";
      user.email = "marc@marcpartensky.com";
      # global = {
      # 	name = "marc";
      #  	email = "marc@marcpartensky.com";
      # };
      core.editor = "nvim";
    };
    # aliases = {
    #   ci = "commit";
    #   co = "checkout";
    #   s = "status";
    # };
  };
}
