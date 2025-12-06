{ pkgs, ... } : {
  # home.packages = [ pkgs.catppuccin-mako ];
  services.dunst.enable = false;
  services.mako = {
    enable = true;
    # theme = "${pkgs.catppuccin-mako}/share/mako/themes/catppuccin-mocha";
    settings = {
      max-visible = 5;
      sort = "-time";
      layer = "top";
      anchor = "top-right";
      font = "meslo-lgs-nf 12";
      background-color = "#040c16bb";
      text-color = "#cce9ea";
      width = 300;
      height = 300;
      margin = 10;
      padding = 15;
      border-size = 2;
      border-color = "#92bbed";
      border-radius = 3;
      # progress-color = "over #5588AAFF";
      progress-color = "#5588AAFF";
      icons = true;
      markup = true;
      actions = true;
      max-icon-size = 64;
      # format = "<b>%s</b>\n%b";
      default-timeout = 7000;
      ignore-timeout = false;

      "urgency=low" = {
        border-size = 1;
        border-color = "#bbbbbb";
      };

      "urgency=high" = {
        border-size = 4;
        border-color = "#E6676B";
      };
    };
  };
}
