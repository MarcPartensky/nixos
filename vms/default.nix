# Common base of the microvm.nix dev VMs (input `microvm` of the flake).
#
# One VM = this module + vms/<name>.nix + two entries in flake.nix
# (nixosConfigurations.<name> and packages.x86_64-linux.<name>).
# Full example and instructions: vms/dev.nix.
#
# Why the build is fast:
#   - tower's /nix/store is shared over 9p (read-only): no
#     squashfs/erofs store image is built, and everything tower has already
#     built or downloaded is directly available in the VM
#     (`nix shell`, `nix develop`, run a store binary: 0 build);
#   - same nixpkgs as the host: the guest kernel is the derivation of
#     tower's boot.kernelPackages, so already in the store;
#   - /nix/store is mounted on top of a writable overlay placed on a small
#     disk (nix-store-overlay.img): `nix build` works INSIDE the VM.
# The rest (/ /var /home) is a tmpfs: each boot starts clean.
{
  config,
  lib,
  pkgs,
  ...
}: {
  microvm = {
    hypervisor = "qemu";

    # optimize = false: microvm.nix otherwise compiles a variant of qemu without
    # GUI (`minimal = true`) that is in no binary cache (28 min of
    # local compilation) AND that is compiled without qemu's user network
    # (slirp): `-netdev user` therefore fails at startup. The standard qemu_kvm
    # (same version, with slirp) is in cache.nixos.org: nothing to build.
    optimize.enable = false;

    # Resources; override in vms/<name>.nix. Do NOT set mem = 2048
    # (exact value that blocks qemu, cf. microvm.nix#171).
    vcpu = lib.mkDefault 4;
    mem = lib.mkDefault 4096;

    shares = [
      {
        tag = "ro-store";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        # 9p is built into qemu (no need for virtiofsd, unlike
        # proto = "virtiofs" which assumes the microvm host module + systemd).
        proto = "9p";
      }
    ];

    # Writable store overlay: lower = /nix/.ro-store, upper = the disk
    # below. The disk is created at the first launch (path relative to the
    # state directory from which the runner runs, cf. `just vm` recipe).
    writableStoreOverlay = "/nix/.rw-store";
    volumes = [
      {
        image = "nix-store-overlay.img";
        mountPoint = config.microvm.writableStoreOverlay;
        size = 8192; # MB, sparse file (only occupies what is written)
      }
    ];

    # slirp (user) network: the VM goes out on the Internet, and the
    # forwardPorts ports are redirected from tower (bind 127.0.0.1 only).
    interfaces = [
      {
        type = "user";
        id = "user";
        mac = "02:00:00:1f:1d:01"; # change per VM (cosmetic, isolated networks)
      }
    ];
    forwardPorts = [
      # ssh into the VM from tower
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 2222;
        guest.port = 22;
      }
    ];

    # No graphical window: the console is displayed on the serial port in the terminal
    # that launches the VM (qemu -nographic), with marc's autologin.
    graphics.enable = false;
  };

  # --- Boot optimizations ---
  # `microvm.optimize.enable = false` above prevents recovering those of the
  # microvm module (it couples them to a qemu without slirp): we take them back here
  # as they are, without touching the qemu package.
  documentation.enable = lib.mkDefault false; # docs are heavy, useless in a VM
  boot = {
    initrd.systemd.enable = lib.mkDefault true; # initrd systemd: much faster boot
    swraid.enable = lib.mkDefault false;
    kernelParams = ["8250.nr_uarts=1"]; # a single serial console
  };
  networking.useNetworkd = lib.mkDefault true; # networkd rather than dhcpcd (faster)
  systemd.network.wait-online.enable = lib.mkDefault false; # bug systemd#29388
  systemd.tpm2.enable = lib.mkDefault false;

  # --- Minimal guest system ---
  system.stateVersion = "25.11";
  networking.hostName = lib.mkDefault "vm-dev"; # vms/<name>.nix sets the real name
  networking.useDHCP = true; # the slirp interface needs a DHCP lease
  networking.firewall.enable = false; # NAT; only the forwardPorts ports are reachable

  time.timeZone = "America/New_York";

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "no";
  };

  # Serial console: direct shell as marc (local sandbox, disposable).
  services.getty.autologinUser = "marc";

  users.users.marc = {
    isNormalUser = true;
    description = "Marc Partensky";
    shell = pkgs.zsh;
    extraGroups = ["wheel" "kvm"];
    # Same hash as users.nix (tower's): console login by password
    # possible if the autologin is removed.
    hashedPassword = "$6$dE28cUDZ9G81wzwo$JoO.6M91zdtR0ja/g1pw/LKE8aAMugmGkIyOiSuqdjEWVKId9F2jxqdvh5Bo69uOC3/g7uP6O3mZmzxqD2pKU1";
    openssh.authorizedKeys.keys = [
      # marc's key (users.nix)
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiUE73uIEgijfmSsDwBvZmecQnqjBUPRKlMDmevsThc1YJNWEHl57NNIUcx6XSCDPKu5azayImLqIBt8wT5xlqtNX20uCnikDfXZ8gFbGlMRTGZKutQZIRmUrUS5mz97S4dVVK+n5WU+OwOfEg/XKXPh4WbTVDpfTTg7RopRAXkma56HV2TJM0ndPRN8VLmBmtnwdQwEpJ0tRRY+KOHmTojsH65eaZ89+BHbto+Kg+lk6x8IH5VDCRQNHgTEccOpOGYBSHRpoZi1a5h3yajf/eGAQ9Cd38DOsfMtm84oFlii7oXPyxwXoM+uH1SDnvLXyheIrV/XLUurSbEb4aJni6Zu79Z9l8xHhUNmVNSZqWOWUvPbAHlDKUzsbxgk9Zs9OTvSDaRzGhViYl4e1Qc993yerGSW1HHIvYUKM7o5nSQqskSOvOI+ahL5fIbgdyVx4FeuURZIyZSxCz4jIJTK15/6pkT/miHKv+vmQhsoLCqgyXY4SG1p9ruzKkzBe03ZQVW5WeFDLYRjZ+Z4Q2IL2K3BmLgp8tInkPJizQ7v5UGSiajJmPxY0j+CqdH9ZlIBdf8GS+run/N4hpMC1/ayUZRbCY5jg4c8bev8dKEZYJKPs/Hq2zLRZe4YtxcKuiGhgIwQOzo/QrCvSM4pVDgo+d2DjEzIdapqE8hF6BHWDg/w== marc.partensky@gmail.com"
      # hermes agent key (debug / help from tower)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower"
    ];
  };
  security.sudo.wheelNeedsPassword = false; # disposable configuration

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "marc"];
    # do not enable auto-optimise-store: incompatible with writableStoreOverlay
  };

  # Deliberately light: everything else is fetched from tower's shared
  # store (`nix shell`/`nix develop`) or added in vms/<name>.nix.
  environment.systemPackages = with pkgs; [
    curl
    fd
    git
    htop
    jq
    just
    neovim
    ripgrep
    rsync
    tmux
    tree
    unzip
    vim
    wget
  ];

  # /home is a tmpfs recreated at each boot: without ~/.zshrc, zsh launches its
  # "new user" assistant at each login. We drop a minimal rc.
  system.activationScripts.vm-zshrc = ''
    install -D -o marc -g users -m 0644 ${pkgs.writeText "vm-zshrc" "# Disposable dev VM: redirected ports listed in the motd\nautoload -Uz compinit && compinit -C\nalias ll='ls -alF'\nexport EDITOR=nvim\n"} /home/marc/.zshrc
  '';

  # motd generated from microvm.forwardPorts: the VM -> tower port
  # mapping is displayed at login (and follows any change of the forwards).
  # Since 26.05 users.motd no longer writes /etc/motd: pam_motd displays it
  # directly, and the sshd/login modules already enable it (showMotd = true).
  users.motd = let
    sshRule = lib.findFirst (p: p.guest.port == 22) null config.microvm.forwardPorts;
    appRules = builtins.filter (p: p.guest.port != 22) config.microvm.forwardPorts;
    addr = p: if p.host.address == "" then "127.0.0.1" else p.host.address;
  in ''
    microvm.nix dev VM: tower's /nix/store shared.
    ${lib.optionalString (sshRule != null) "  ssh from tower  : ssh -p ${toString sshRule.host.port} marc@127.0.0.1\n"}${lib.concatMapStringsSep "\n" (p: "  VM port ${toString p.guest.port}  ->  http://${addr p}:${toString p.host.port} on tower") appRules}
      host code        : microvm.shares (see vms/<name>.nix)
      shutdown         : poweroff, or <state>/current/bin/microvm-shutdown
  '';
}
