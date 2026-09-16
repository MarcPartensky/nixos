{inputs, ...}: {
  imports = [inputs.jovian.nixosModules.default];

  jovian.steam = {
    enable = true;
    autoStart = true;
    user = "marc";
    desktopSession = "niri";
  };
}
