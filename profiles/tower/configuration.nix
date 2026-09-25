{
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ../../hosts/tower/disko.nix
    ../../hosts/laptop/hardware-configuration.nix
  ];

  boot.kernelParams = ["panic=10"]; # reboot 10 s après un kernel panic, le dump reste dans pstore
  systemd.settings.Manager.RuntimeWatchdogSec = "30s"; # reboot si la machine gèle (si `sudo wdctl` trouve un watchdog)
  # boot.initrd.clevis.enable = true;
  # boot.initrd.clevis.devices."zroot/root".secretFile = ./zfs.jwe; # ton encryptionroot
  # boot.initrd.availableKernelModules = ["tpm_crb"]; # driver du fTPM AMD
  boot.initrd.secrets."/etc/secrets/zfs-root.key" = "/etc/secrets/zfs-root.key"; # entre guillemets, sinon la clé finit dans le /nix/store lisible par tous

  networking.firewall = {
    enable = true;

    allowedTCPPorts = [
      2022
      8083 # Pangolin / Apps
      8050
      5432 # PostgreSQL
      6080 # noVNC (client VNC web de la session niri) ; wayvnc reste sur loopback
    ];
  };

  networking.hostName = "tower";
  sops.defaultSopsFile = lib.mkForce ../../secrets/tower.yml;
}
