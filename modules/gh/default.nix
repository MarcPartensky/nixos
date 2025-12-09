{ pkgs, ...} :
{
  programs.gh = {
    enable = true;
    extensions = [
      pkgs.gh-eco
    ];
    settings = {
      git_protocol = "ssh";
    };
  };
  programs.gh-dash.enable = true;
}
