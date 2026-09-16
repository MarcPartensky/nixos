{
  inputs,
  lib,
  ...
}: {
  imports = [inputs.jovian.nixosModules.default];

  jovian.steam = {
    enable = true;
    autoStart = true; # Jovian gère lui même le login
    user = "marc";
    desktopSession = "niri"; # "Switch to Desktop" relance niri
  };

  # autoStart est incompatible avec un autre display manager
  services.displayManager.sddm.enable = lib.mkForce false;
}
