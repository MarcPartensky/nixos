{
  config,
  lib,
  pkgs,
  ...
}:
# Turn the internal panel off after a period without input, WITHOUT suspending the
# machine.
#
# Why not a compositor idle daemon: Steam Gaming Mode runs gamescope, which
# implements no idle protocol at all (no ext-idle-notify-v1, no idle-inhibit, no
# org.kde.kwin.idle) and holds the DRM master, so swayidle/wlopm do nothing there.
# Steam's own "Turn off screen after" only dims the backlight to ~3 % on the Deck
# under gamescope (ValveSoftware/SteamOS#2877), so the panel stays faintly lit for
# days. This service reads /dev/input/event* directly (keyboard AND gamepad, Steam
# Input re-emits the controller on evdev) and cuts the backlight; the first input
# brings it back. Nothing is suspended: builds, the Windmill worker and the Monero
# miner keep running.
let
  cfg = config.services.panelIdleOff;
in {
  options.services.panelIdleOff = {
    enable = lib.mkEnableOption "powering the panel backlight off after idle, without suspending";

    idleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Seconds without input before the panel is turned off.";
    };

    backlight = lib.mkOption {
      type = lib.types.str;
      default = "amdgpu_bl0";
      description = "Backlight device under /sys/class/backlight (Steam Deck: amdgpu_bl0).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.panel-idle-off = {
      description = "Turn the panel backlight off after idle (no suspend)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./panel-idle-off.py}";
        Restart = "always";
        RestartSec = 5;
        # /dev/input stays available (no PrivateDevices) and sysfs stays writable
        # (no ProtectKernelTunables): both are the whole point of this service.
        NoNewPrivileges = true;
        ProtectHome = true;
      };
      environment = {
        IDLE_SECONDS = toString cfg.idleSeconds;
        BACKLIGHT = cfg.backlight;
      };
    };
  };
}
