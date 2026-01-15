{ ...} : {
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      # "application/pdf" = [ "org.pwmt.zathura.desktop" ];
      "application/pdf" = [ "firefox.desktop" ];
    };
  };
  # xdg.portal = {
  #   enable = true;
  #   config.common.default = "*";
  #   extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  # };
}
