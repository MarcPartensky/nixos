{
  pkgs,
  lib,
  ...
}: {
  security.rtkit.enable = true;
  hardware.bluetooth.enable = true; # enables support for Bluetooth
  hardware.bluetooth.powerOnBoot = true; # powers up the default Bluetooth controller on boot
  hardware.bluetooth.settings = {
    General = {
      ControllerMode = "bredr"; # Fix frequent Bluetooth audio dropouts
      Experimental = true;
      FastConnectable = true;
      Disable = "input";
      ClassicBondedOnly = false;
      # Essential for pairing with the Switch
      Class = "0x000540";
      # ControllerMode = "dual";
      # Enable = "Source,Sink,Media,Socket";
      AutoConnect = true; # Tries to connect to known devices
      # Tries to reconnect even if the device seems "off"
      ReconnectAttempts = 7;
      ReconnectIntervals = "1, 2, 4, 8, 16, 32, 64";
    };
    Policy = {
      ReconnectAttempts = 10;
      ReconnectIntervals = 4;
      AutoEnable = true;
    };
  };

  # systemd.services.bluetooth.serviceConfig.ExecStart = [
  #   ""
  #   "${pkgs.bluez}/get/bluetooth/bluetoothd --compat"
  # ];

  services.blueman.enable = true;

  services.pipewire.wireplumber.extraConfig."51-bluez" = {
    "monitor.bluez.properties" = {
      "bluez5.enable-sbc-xq" = true;
      "bluez5.enable-msbc" = true;
      "bluez5.enable-hw-volume" = true;
      "bluez5.roles" = ["a2dp_sink" "a2dp_source" "hsp_hs" "hsp_ag" "hfp_hf" "hfp_ag"]; # bap_* removed
    };
  };
  systemd.user.services.mpris-proxy = {
    description = "Mpris proxy";
    after = ["network.target" "sound.target"];
    wantedBy = ["default.target"];
    serviceConfig.ExecStart = "${pkgs.bluez}/bin/mpris-proxy";
  };

  systemd.user.services.bluetooth-autoconnect = {
    description = "Force Bluetooth connection on login";
    after = ["graphical-session.target"];
    wantedBy = ["graphical-session.target"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "bt-auto" ''
        # Wait until the blueman agent is really up
        sleep 5
        # Try to connect all trusted devices
        ${pkgs.bluez}/bin/bluetoothctl devices Paired | cut -d ' ' -f 2 | while read -r mac; do
          ${pkgs.bluez}/bin/bluetoothctl connect "$mac"
        done
      '';
    };
  };
}
