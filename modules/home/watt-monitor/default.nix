{
  config,
  pkgs,
  lib,
  ...
}: let
  hasBattery =
    builtins.pathExists /sys/class/power_supply/BAT0
    || builtins.pathExists /sys/class/power_supply/BAT1;

  watt-monitor = pkgs.rustPlatform.buildRustPackage rec {
    pname = "watt-monitor";
    version = "main";
    src = pkgs.fetchFromGitHub {
      owner = "jookwang-park";
      repo = "watt-monitor-rs";
      rev = "main";
      hash = "sha256-4xK3v7OvP4eybKraH4mrANlDLNrB1N75g8xkGPeffm8=";
    };
    cargoHash = "sha256-6WAsvlJ4NcOyWBTbcFeMFLLbG5RqBd5wMu6s1GyglBI=";
  };
in {
  home.packages = lib.mkIf hasBattery [watt-monitor];

  systemd.user.services.watt-monitor = lib.mkIf hasBattery {
    Unit.Description = "Watt Monitor Background Daemon";
    Service = {
      ExecStart = "${pkgs.bash}/bin/sh -c '${watt-monitor}/bin/watt-monitor daemon || ${watt-monitor}/bin/watt-monitor'";
      Restart = "always";
    };
    Install.WantedBy = ["default.target"];
  };
}
