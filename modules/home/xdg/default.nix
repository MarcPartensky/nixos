{...}: {
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "application/pdf" = ["org.pwmt.zathura.desktop"];
      # "application/pdf" = [ "firefox.desktop" ];
    };
  };

  xdg.desktopEntries.ib-tws = {
    name = "Interactive Brokers TWS";
    genericName = "Trading Workstation";
    exec = "steam-run /home/marc/Jts/tws";
    terminal = false;
    categories = ["Application" "Network" "Finance"];
    icon = "utilities-terminal"; # Pareil, à remplacer si tu as une belle icône
  };

  # xdg.portal = {
  #   enable = true;
  #   config.common.default = "*";
  #   extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  # };
}
