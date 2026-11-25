{
  pkgs,
  lib,
  ...
}: {
  # 1. Enable Niri (handles the installation and the session file)
  programs.niri.enable = true;

  # 2. Configure the Display Manager (SDDM)
  services.displayManager = {
    sddm.enable = lib.mkDefault true;
    sddm.wayland.enable = true; # Recommended for Niri (native Wayland)

    # 3. Configure AutoLogin
    autoLogin = {
      enable = true;
      user = "marc"; # <--- Replace with your username
    };

    # Set the default session to niri
    defaultSession = lib.mkDefault "niri";
  };
}
