{ pkgs, lib, ... }: {

  hardware.bluetooth.enable = true; # enables support for Bluetooth
  hardware.bluetooth.powerOnBoot = true; # powers up the default Bluetooth controller on boot
  hardware.bluetooth.settings = {
    General = {
        # ControllerMode = "bredr"; # Fix frequent Bluetooth audio dropouts
        Experimental = true;
        FastConnectable = true;
        Disable = "input";
        ClassicBondedOnly = false;
          # Indispensable pour l'appairage avec la Switch
        Class = "0x000540"; 
        ControllerMode = "dual";
        Enable = "Source,Sink,Media,Socket";
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

  systemd.user.services.mpris-proxy = {
    description = "Mpris proxy";
    after = [ "network.target" "sound.target" ];
    wantedBy = [ "default.target" ];
    serviceConfig.ExecStart = "${pkgs.bluez}/bin/mpris-proxy";
  };

}
