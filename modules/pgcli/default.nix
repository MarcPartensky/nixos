{ pkgs, ...}:
{
  programs.pgcli = {
    enable = true;
    settings = {
      main = {
        smart_completion = true;
        vi = true;
      };
      # "named queries".simple = "select * from abc where a is not Null";
    }
  };
}
