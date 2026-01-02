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
        AutoConnect = true; # Tente de se connecter aux périphériques connus
        # Tente de se reconnecter même si le périphérique semble "éteint"
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

  systemd.user.services.mpris-proxy = {
    description = "Mpris proxy";
    after = [ "network.target" "sound.target" ];
    wantedBy = [ "default.target" ];
    serviceConfig.ExecStart = "${pkgs.bluez}/bin/mpris-proxy";
  };

  systemd.user.services.bluetooth-autoconnect = {
    description = "Force Bluetooth connection on login";
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "bt-auto" ''
        # On attend que l'agent blueman soit bien up
        sleep 5
        # On tente de connecter tous les appareils de confiance (trusted)
        ${pkgs.bluez}/bin/bluetoothctl devices Paired | cut -d ' ' -f 2 | while read -r mac; do
          ${pkgs.bluez}/bin/bluetoothctl connect "$mac"
        done
      '';
    };
  };

}
