{ pkgs, ... }:

{
  programs.wofi = {
    enable = true;
    settings = {
      show = "drun";
      width = 750;
      height = 400;
      always_parse_args = true;
      show_all = false;
      term = "alacritty";
      hide_scroll = true;
      print_command = true;
      insensitive = true;
      prompt = "";
      columns = 2;
    };

    style = builtins.readFile ./style.css;
  
    # style = ''
    #   window {
    #     background-color: #7c818c;
    #   }
    # '';
  };
}
