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
  # vkms = écran virtuel. Sans écran branché (DP-1/DP-2/HDMI-A-1 en disconnected sur
  # le Renoir), niri n'a AUCUNE sortie vidéo : wayvnc sort en "No output found" et
  # il n'y a rien à afficher en VNC. vkms crée une sortie virtuelle que niri adopte.
  boot.kernelModules = ["vkms"];
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
