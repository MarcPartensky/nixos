{ pkgs, ...} : {
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      # "application/pdf" = [ "org.pwmt.zathura.desktop" ];
      "application/pdf" = [ "firefox.desktop" ];
    };
  };
}
