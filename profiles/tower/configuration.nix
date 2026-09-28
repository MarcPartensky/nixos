{
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ../../hosts/tower/disko.nix
    ../../hosts/laptop/hardware-configuration.nix
    # config herdr de marc (~/.config/herdr/config.toml) : affiche le modele
    # hermes de chaque pane dans la sidebar. Voir modules/nixos/herdr/.
    # Posee cote systeme (symlink vers le store) : le build systeme (root) ne
    # construit PAS la conf home-manager de marc, qui reste standalone
    # (`HM=marc just home` / homeConfigurations.marc).
    ../../modules/nixos/herdr
  ];

  # Sessions hermes lancees par marc (panes herdr, HERMES_HOME partage, cf
  # users/marc/home.nix) : elles ecrivent dans /var/lib/hermes/.hermes. Le
  # groupe hermes (users.nix) plus les chmod g+rw du module hermes couvrent
  # l'existant ; ces ACL garantissent la traversee de /var/lib/hermes (2770) et
  # que les fichiers crees par marc restent lisibles par le service.
  # Pattern repris de services/firefox-mcp et amazon-mcp.
  systemd.tmpfiles.rules = [
    "a /var/lib/hermes - - - - u:marc:--x,m::rwx"
    "a /var/lib/hermes/.hermes - - - - u:marc:rwx,d:u:marc:rwx,m::rwx,d:m::rwx"
    "a /var/lib/hermes/.hermes/plugins - - - - u:marc:rwx,d:u:marc:rwx,m::rwx,d:m::rwx"
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

  # Clé ed25519 du Mac de marc : connexion Hermes Desktop de type SSH
  # (user@host = hermes@tower, auth par clé, pas de mot de passe).
  # Déclaratif exprès : /var/lib/hermes est en 2770 (écriture groupe, requis par
  # le partage hermes/marc) et sshd (StrictModes, cf services/hermes) ignore
  # alors %h/.ssh/authorized_keys. Cette option écrit /etc/ssh/authorized_keys.d/
  # hermes en root 444, qui passe le contrôle, et survit aux rebuilds.
  users.users.hermes.openssh.authorizedKeys.keys = lib.mkAfter [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdX5m7b8xWL/9ZUeFRxahB4YY0v2rAV5CCFv8xTOlUh marc@Air-de-Marc"
  ];

  networking.hostName = "tower";
  sops.defaultSopsFile = lib.mkForce ../../secrets/tower.yml;

  # Token Matrix du bot @hermes : seul tower est destinataire du fichier sops
  # (secrets/hermes-matrix.yml). Les autres hôtes qui importent services/hermes
  # (laptop, anywhere) ne doivent PAS le déclarer. Voir services/hermes.
  services.hermes.enableMatrixToken = true;

  # Token du bot Discord dédié (voix + texte natifs, profil `discord-bridge`) :
  # même règle, secrets/hermes-discord.yml n'a que tower comme destinataire.
  services.hermes.enableDiscordToken = true;
}
