{ pkgs, ... }:
{
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "NetworkManager.service" &&
          subject.user == "marc") {
        return polkit.Result.YES;
      }
    });
  '';
}
