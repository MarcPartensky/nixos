# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
{
  lib,
  pkgs,
  inputs,
  ...
}: let
  packages = import ./packages.nix {inherit pkgs inputs;};
in {
  imports = [
    inputs.disko.nixosModules.disko
    inputs.nixvim.nixosModules.default
    # inputs.catppuccin.nixosModules.catppuccin
    inputs.sops.nixosModules.sops # Inclus dans sopswarden
    inputs.hermes-agent.nixosModules.default
    # inputs.sopswarden.nixosModules.default
    # inputs.microvm.nixosModules.microvm
    inputs.home-manager.nixosModules.default

    # Root of the tailnet's internal CA (Smallstep, modules/nixos/intra-ca):
    # signs the short names of the tower proxy (`https://mesh`,
    # `https://jellyfin`). Public certificate, the root key is on no
    # machine of the flake.
    ../../modules/nixos/intra-ca-trust.nix

    ../../users.nix

    # Fleet availability: tuptime keeps the local uptime/downtime
    # history of the machine (it survives a network outage), and the Zabbix
    # agent pushes to the server that lives on the VPS. See services/tuptime and
    # services/zabbix.
    ../../services/tuptime
    ../../services/zabbix/agent.nix

    # Include the results of the hardware scan.
    # ../../services
    # ../../modules/nixos/iso # not the way to build iso
    ../../modules/nixos/bluetooth
    ../../modules/nixos/networking
    ../../modules/nixos/pipewire
    ../../modules/nixos/keyd
    ../../modules/nixos/gnupg
    # ../../modules/nixos/zsh
    ../../modules/nixos/zfs
    ../../modules/nixos/virt-manager
    ../../modules/nixos/podman
    ../../modules/nixos/flatpak
    # ../../modules/nixos/sopswarden
    ../../modules/nixos/xdg
    ../../modules/nixos/sddm # greetd or ly
    ../../modules/nixos/polkit
    # htop: shared /etc/htoprc (columns and CPU/RAM screens, see the htoprc).
    ../../modules/nixos/htop
    # ../../modules/generations
    # ../../modules/git
    # ./modules/librewolf
  ];

  programs.zsh.enable = true;
  programs.ydotool.enable = true;

  home-manager.extraSpecialArgs = {inherit inputs;};
  home-manager.users.root = ../../users/root/home.nix;

  sops.defaultSopsFile = ../../secrets/common.yml;

  environment.pathsToLink = [
    "/share/applications"
    "/share/xdg-desktop-portal"
  ];

  services.gnome.gnome-keyring.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;
  # The file is encrypted with SOPS, so no need to disable validation

  nix.settings = {
    experimental-features = "nix-command flakes";
    max-jobs = 6;
    download-buffer-size = 524288000;
    # hermes must be a TRUSTED user for remote builds and for `nix copy`
    # between the mesh hosts: an untrusted ssh user cannot serve build
    # results. It is not a privilege escalation here, hermes already runs
    # nixos-rebuild through the gated wrapper.
    trusted-users = [ "root" "hermes" ];
  };
  security.polkit.enable = true;

  # sudo keeps the caller's umask by default: an activation launched from a
  # hermes session (umask 077) wrote /etc/passwd and /etc/group as 0600
  # (File::Slurp masks the permissions with the process umask) and broke every
  # non-root user lookup (incident of 03/11/2026). Force umask 0022 for EVERY
  # command run through sudo.
  security.sudo.extraConfig = ''
    Defaults umask = 0022
    Defaults umask_override
  '';
  # services.polkit-gnome-authentication-agent.enable = true;

  # nix.settings = {
  #   substituters = [ "https://claude-code.cachix.org" ];
  #   trusted-public-keys = [ "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk=" ];
  # };
  # nixpkgs.overlays = [ inputs.claude-code.overlays.default ];

  # TEMPORARY
  nixpkgs.config.allowUnfree = true;
  # nixpkgs.config.permittedInsecurePackages is a "last wins" attrs:
  # several modules (matrix-whatsapp, pangolin, packages.nix) redefine it
  # each on their side and silently overwrite each other. Explicit union here while
  # waiting to centralize for good.
  nixpkgs.config.permittedInsecurePackages = [
    "libsoup-2.74.3"
    "olm-3.2.16" # mautrix crypto deps (whatsapp/discord/...)
    "pangolin-1.10.3"
    "beekeeper-studio-5.3.4"
  ];

  hardware.graphics.enable = true;

  services.xserver.videoDrivers = ["nvidia"];

  services.openssh.settings.MaxAuthTries = 10; # default = 6

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = false;
    open = false; # The MX150 is old, uses proprietary drivers
    nvidiaSettings = true;

    # PRIME configuration (Offload)
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      # Find your IDs with `lspci | grep -E "VGA|3D"`
      # Usually for an i7-8550U + MX150 it is:
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  # hardware.cpu.intel.updateMicrocode = true;
  # hardware.firmware = [ pkgs.linux-firmware ];
  # networking.firewall.enable = false;

  users.defaultUserShell = pkgs.zsh;

  # Set your time zone.
  # time.timeZone = "Europe/Paris";
  time.timeZone = "America/New_York";
  # time.timeZone = "Asia/Bangkok";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };
  boot.kernelModules = ["uinput" "hid-nintendo" "uhid"];

  environment.systemPackages = packages.all;

  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) (map (p: lib.getName p) packages.unfree);

  # In your configuration.nix (system)
  services.dbus.enable = true;
  xdg.portal.enable = true;

  # Fonts
  fonts.packages = with pkgs; [
    # Nerd fonts
    # nerdfonts
    nerd-fonts.droid-sans-mono
    meslo-lgs-nf
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  programs.mtr.enable = true;

  services.ratbagd.enable = true;

  services.power-profiles-daemon.enable = true;

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc
    zlib
    # Add other libs here if other packages complain
  ];

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrted your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.11"; # Did you read the comment?
}
