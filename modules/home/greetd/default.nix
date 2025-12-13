{ pkgs, ... } : {
  services = {
    greetd = {
      enable = true;
      settings = {
        initial_session = {
          # Change "Hyprland" to the command to run your window manager. ^Note1
          command = "Hyprland";
          # Change "${user}" to your username or to your username variable.
          user = "${user}";
        };
        # By adding default_session it ensures you can still access the tty terminal if you logout of your windows manager otherwise you would just relaunch into it.
        default_session = {
          # Again here just change "-cmd Hyprland" to "-cmd your-start-command".
          command = "${pkgs.greetd.tuigreet}/bin/tuigreet --greeting 'Welcome To NixOS' --asterisks --remember --remember-user-session --time -cmd Hyprland";
          # DO NOT CHANGE THIS USER
          user = "greeter";
        };
      };
    };
  };
}
