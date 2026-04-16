{lib, ...}: let
  hasBattery =
    builtins.pathExists /sys/class/power_supply/BAT0
    || builtins.pathExists /sys/class/power_supply/BAT1;
in {
  services.batsignal = lib.mkIf hasBattery {
    enable = true;
    extraArgs = ["-p" "-m" "1" "-a" "ADP0"];
  };
}
