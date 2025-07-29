{ pkgs, ...} : {
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (subject.isInGroup("wheel"))
        return polkit.Result.YES;
    });
  '';


  # home-manager.users.marc = { pkgs, inputs, ... }: {
  #   systemd.user.services.polkit-gnome-authentication-agent-1 = {
  #     Unit = {
  #       Description = "polkit-gnome-authentication-agent-1";
  #       Wants = [ "graphical-session.target" ];
  #       After = [ "graphical-session.target" ];
  #     };
  #     Install = {
  #       WantedBy = [ "graphical-session.target" ];
  #     };
  #     Service = {
  #       Type = "simple";
  #       ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
  #       Restart = "on-failure";
  #       RestartSec = 1;
  #       TimeoutStopSec = 10;
  #     };
  #   };
  # };
}
