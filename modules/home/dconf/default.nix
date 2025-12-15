{ pkgs, ... }:
{
  dconf.enable = true;
  dconf.settings = {
    "org/gnome/desktop/media-handling" = {
      automount = true;
      automount-open = true;
    };
    "org/gnome/nautilus/preferences" = {
      default-folder-viewer = "'list-view'";
    };
    "org/gnome/nautilus/list-view" = {
      sort-column = "'modified'";
      sort-order  = "'descending'";
    };
  };
}
