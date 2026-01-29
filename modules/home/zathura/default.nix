{ ... }: {
  programs.zathura = {
    enable = true;
    options = {
      # recolor = true; # dark background default
      # recolor-keephue = false;
      
      # default-bg = "#000000";
      # default-fg = "#ffffff";
      
      # recolor-lightcolor = "#000000";
      # recolor-darkcolor = "#ffffff";
      selection-clipboard = "clipboard";
    };
  };
}
