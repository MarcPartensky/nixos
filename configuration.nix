{
    my-config, zfs-root, inputs, pkgs, lib, ... 
}: 
let 
  kubeMasterIP = "10.1.1.2";
  kubeMasterHostname = "api.kube";
  kubeMasterAPIServerPort = 6443;
  # tokyo-night-sddm = pkgs.libsForQt5.callPackage ./themes/tokyo-night-sddm.nix { };
  sddm-peace-color = pkgs.libsForQt5.callPackage ./themes/sddm-peace-color.nix { };
  # sddm-apple = pkgs.libsForQt5.callPackage ./themes/sddm-apple.nix { };
  unstable = import <nixpkgs-unstable> { config.allowUnfree = true; };
in
{
  # load module config to top-level configuration
  inherit my-config zfs-root;

  # Let 'nixos-version --json' know about the Git revision
  # of this flake.
  system.configurationRevision = if (inputs.self ? rev) then
    inputs.self.rev
  else
    throw "refuse to build: git tree is dirty";


  system.stateVersion = "23.11";
 
  # system.activationScripts = {
  #   enableLingering = ''
  #     # remove all existing lingering users
  #     rm -r /var/lib/systemd/linger
  #     mkdir /var/lib/systemd/linger
  #     # enable for the subset of declared users
  #     touch /var/lib/systemd/linger/marc
  #   '';
  # };

  # config.systemd.user.services.nixos-activation.unitConfig.ConditionUser = mkForce
  #   [
  #     "!@system"
  #     "!marc"
  #   ];

  boot.zfs.forceImportRoot = lib.mkDefault false;
  # boot.loader.systemd-boot.enable = true;
  boot.initrd.systemd.enable = true;
  # boot.loader.efi.canTouchEfiVariables = true;
  boot.plymouth.enable = true;
  boot.plymouth.theme = "breeze";

  virtualisation.docker.enable = true;

  # Enable NetworkManager for wireless networking,
  # You can configure networking with "nmtui" command.
  # networking.useDHCP = true;
  networking.hostName = "tower";
  networking.networkmanager.enable = true;
  networking.wireless.iwd.enable = true;
  networking.networkmanager.wifi.backend = "iwd";

  services = {
    # plex = {
    #     enable = true;
    #     dataDir = "/var/lib/plex";
    #     openFirewall = true;
    #     user = "plex";
    #     group = "plex";
    # };
    # hardware.pulseaudio.enable = true;
    # services.transmission.settings = {
    #     download-dir = "${config.services.transmission.home}/Downloads";
    # };
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      jack.enable = true;
      pulse.enable = true;
      socketActivation = true;
    };
    # Enable the X11 windowing system.
    xserver = {
      enable = true;
      layout = "us";
      videoDrivers = [ "amdgpu" ];
      # windowManager.i3.enable = true;
      desktopManager.plasma5.enable = true;
      desktopManager.xterm.enable = true;
      displayManager = { 
        defaultSession = "hyprland"; 
        # autoLogin = { 
        #   enable = true; 
        #   user = "marc"; 
        # }; 
        sddm = {
          enable = false;
          # wayland.enable = true;
          # theme = "sddm-apple";
          theme = "sddm-peace-color";
        };
        lightdm = { 
          enable = false; 
        #   greeter.enable = true; fonts
        }; 
        gdm.enable = true;
        session = [
          # {
          #   manage = "desktop";
          #   name = "xterm";
          #   start = ''
          #     ${pkgs.xterm}/bin/xterm -ls &
          #     waitPID=$!
          #   '';
          # }
          {
            manage = "desktop";
            name = "firefox";
            start = ''
              ${pkgs.firefox}/bin/firefox &
              waitPID=$!
            '';
          }
        ];
      };
    };
    openssh = {
      enable = lib.mkDefault true;
      settings = { PasswordAuthentication = lib.mkDefault true; };
    };
  };

  hardware.bluetooth.enable = true;

  # amd support with vulkan
  hardware.opengl.driSupport  = true;
  hardware.opengl.extraPackages = with pkgs; [
     rocm-opencl-icd
     rocm-opencl-runtime
     amdvlk
  ];


  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    liberation_ttf
    fira-code
    fira-code-symbols
    mplus-outline-fonts.githubRelease
    dina-font
    proggyfonts
    source-code-pro
  ];


  # services.xserver.enable = true;
  # services.xserver.displayManager.gdm.enable = true;

  programs.hyprland.enable = true;
  programs.dconf.enable = true; # apply gtk themes in wayland apps

  users.users = {
    root = {
      isNormalUser = false;
      shell = pkgs.zsh;
      initialHashedPassword = "$6$0QAYnBqAJtqB12p3$2lb7rAS2sYw49GUJt0L0bAEpZJSv4HZARQjlbYPhexSmeRB71IRMBzXjf3b4rX6fuDxOuDLydP/Kni9uraS5j/";
      openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiUE73uIEgijfmSsDwBvZmecQnqjBUPRKlMDmevsThc1YJNWEHl57NNIUcx6XSCDPKu5azayImLqIBt8wT5xlqtNX20uCnikDfXZ8gFbGlMRTGZKutQZIRmUrUS5mz97S4dVVK+n5WU+OwOfEg/XKXPh4WbTVDpfTTg7RopRAXkma56HV2TJM0ndPRN8VLmBmtnwdQwEpJ0tRRY+KOHmTojsH65eaZ89+BHbto+Kg+lk6x8IH5VDCRQNHgTEccOpOGYBSHRpoZi1a5h3yajf/eGAQ9Cd38DOsfMtm84oFlii7oXPyxwXoM+uH1SDnvLXyheIrV/XLUurSbEb4aJni6Zu79Z9l8xHhUNmVNSZqWOWUvPbAHlDKUzsbxgk9Zs9OTvSDaRzGhViYl4e1Qc993yerGSW1HHIvYUKM7o5nSQqskSOvOI+ahL5fIbgdyVx4FeuURZIyZSxCz4jIJTK15/6pkT/miHKv+vmQhsoLCqgyXY4SG1p9ruzKkzBe03ZQVW5WeFDLYRjZ+Z4Q2IL2K3BmLgp8tInkPJizQ7v5UGSiajJmPxY0j+CqdH9ZlIBdf8GS+run/N4hpMC1/ayUZRbCY5jg4c8bev8dKEZYJKPs/Hq2zLRZe4YtxcKuiGhgIwQOzo/QrCvSM4pVDgo+d2DjEzIdapqE8hF6BHWDg/w== marc.partensky@gmail.com" ];
    };
    marc = {
      isNormalUser = true;
      home = "/home/marc";
      description = "Marc Partensky";
      extraGroups = ["wheel" "networkmanager" "docker" "seat" "kvm" "video"];
      # openssh.authorizedKeys.keys = 
      shell = pkgs.zsh;
      initialHashedPassword = "$6$0QAYnBqAJtqB12p3$2lb7rAS2sYw49GUJt0L0bAEpZJSv4HZARQjlbYPhexSmeRB71IRMBzXjf3b4rX6fuDxOuDLydP/Kni9uraS5j/";
      openssh.authorizedKeys.keys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiUE73uIEgijfmSsDwBvZmecQnqjBUPRKlMDmevsThc1YJNWEHl57NNIUcx6XSCDPKu5azayImLqIBt8wT5xlqtNX20uCnikDfXZ8gFbGlMRTGZKutQZIRmUrUS5mz97S4dVVK+n5WU+OwOfEg/XKXPh4WbTVDpfTTg7RopRAXkma56HV2TJM0ndPRN8VLmBmtnwdQwEpJ0tRRY+KOHmTojsH65eaZ89+BHbto+Kg+lk6x8IH5VDCRQNHgTEccOpOGYBSHRpoZi1a5h3yajf/eGAQ9Cd38DOsfMtm84oFlii7oXPyxwXoM+uH1SDnvLXyheIrV/XLUurSbEb4aJni6Zu79Z9l8xHhUNmVNSZqWOWUvPbAHlDKUzsbxgk9Zs9OTvSDaRzGhViYl4e1Qc993yerGSW1HHIvYUKM7o5nSQqskSOvOI+ahL5fIbgdyVx4FeuURZIyZSxCz4jIJTK15/6pkT/miHKv+vmQhsoLCqgyXY4SG1p9ruzKkzBe03ZQVW5WeFDLYRjZ+Z4Q2IL2K3BmLgp8tInkPJizQ7v5UGSiajJmPxY0j+CqdH9ZlIBdf8GS+run/N4hpMC1/ayUZRbCY5jg4c8bev8dKEZYJKPs/Hq2zLRZe4YtxcKuiGhgIwQOzo/QrCvSM4pVDgo+d2DjEzIdapqE8hF6BHWDg/w== marc.partensky@gmail.com" ];
    };
  };

  programs.neovim = {
    enable = true;
    viAlias = true;
    vimAlias = true;
  };

  imports = [
    "${inputs.nixpkgs}/nixos/modules/installer/scan/not-detected.nix"
    # "${inputs.nixpkgs}/nixos/modules/profiles/qemu-guest.nix"
  ];

  nixpkgs = {
    config = {
      allowUnfree = true;
      packageOverrides = pkgs: {
        unstable = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") {};
      };
    };
  };


  # kubernetes https://nixos.wiki/wiki/K3s
  networking.firewall.allowedTCPPorts = [ 6443 5900 ];
  # services.k3s = {
  #   enable = true;
  #   role = "server";
  #   # TODO describe how to enable zfs snapshotter in containerd
  #   extraFlags = toString [
  #     "--container-runtime-endpoint unix:///run/containerd/containerd.sock"
  #   ];
  # };

  # kubernetes zfs support
  # virtualisation.containerd = {
  #   enable = true;
  #   settings =
  #     let
  #       fullCNIPlugins = pkgs.buildEnv {
  #         name = "full-cni";
  #         paths = with pkgs;[
  #           cni-plugins
  #           cni-plugin-flannel
  #         ];
  #       };
  #     in {
  #       plugins."io.containerd.grpc.v1.cri".cni = {
  #         bin_dir = "${fullCNIPlugins}/bin";
  #         conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d/";
  #       };
  #     };
  # };

  # kubernetes support
  # resolve master hostname
  # networking.extraHosts = "${kubeMasterIP} ${kubeMasterHostname}";


  # services.kubernetes = {
  #   roles = ["master" "node"];
  #   masterAddress = kubeMasterHostname;
  #   apiserverAddress = "https://${kubeMasterHostname}:${toString kubeMasterAPIServerPort}";
  #   easyCerts = true;
  #   apiserver = {
  #     securePort = kubeMasterAPIServerPort;
  #     advertiseAddress = kubeMasterIP;
  #   };

  #   # use coredns
  #   addons.dns.enable = true;

  #   # needed if you use swap
  #   kubelet.extraOpts = "--fail-swap-on=false";
  # };


  nix.settings.experimental-features = lib.mkDefault [ "nix-command" "flakes" ];

  programs.git.enable = true;
  programs.zsh.enable = true;

  security = {
    doas.enable = lib.mkDefault true;
    sudo.enable = lib.mkDefault false;
  };

  nix = {
    package = pkgs.nixFlakes;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  # systemd.services.tunneltower = {
  #     enable = true;
  #     description = "Connect to my tower remotely";
  #     unitConfig = {
  #         # Type = "simple";
  #     };
  #     serviceConfig = {
  #         ExecStart = ''
  #         ${pkgs.autossh}/bin/autossh -M 0 \
  #         -o ServerAliveInterval=30 \
  #         -o ServerAliveCountMax=3 \
  #         -o PubkeyAuthentication=yes \
  #         -o PasswordAuthentication=no \
  #         -NR localhost:42070:localhost:22 \
  #         -p 42069 \
  #         -i ~/.ssh/id_rsa \
  #         marc@207.180.235.56
  #         '';
  #     };
  #     wantedBy = [ "multi-user.target" ];
  # };

  boot.kernelParams = [
    "i915.enable_psr=0"
  ];
  powerManagement.enable = false;
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;
  services.xserver.displayManager.gdm.autoSuspend = false;
  environment.etc."systemd/sleep.conf".text = ''
    [Sleep]
    AllowSuspend=no
    AllowHibernation=no
    AllowSuspendThenHibernate=no
    AllowHybridSleep=no
    #SuspendMode=
    #SuspendState=mem standby freeze
    #HibernateMode=platform shutdown
    #HibernateState=disk
    #HybridSleepMode=suspend platform shutdown
    #HybridSleepState=disk
    #HibernateDelaySec=180min
  '';

  systemd.timers.tunneltower = {
    wantedBy = [ "timers.target" ];
      timerConfig = {
        # OnBootSec = "1d";
        # OnUnitActiveSec = "1d";
        Unit = "tunneltower";
        Persistent = true;
        # OnCalendar = "*-*-* 5:00:00";
        OnBootSec="15min";
        OnUnitActiveSec="1d";
      };
  };
  
  #
  # environment.systemPackages = builtins.attrValues {
  #   inherit (pkgs)
  #     k3s
  #     autossh
  #     jq # other programs
  #     neovim
  #     stow
  #     coreutils
  #     gnumake
  #     bat
  #     gnupg
  #     nome-manager
  #     htop
  #     kompose
  #     kubectl
  #     kubernetes
  #     killall
  #     seatd
  #     mcfly
  #     sddm
  #     # tokyo-night-sddm
  #   ;
  # };

  environment.systemPackages = with pkgs;
    [
      k3s
      autossh
      jq # other programs
      neovim
      stow
      coreutils
      gnumake
      bat
      gnupg
      home-manager
      htop
      kompose
      kubectl
      kubernetes
      killall
      seatd
      mcfly
      sddm
      sddm-peace-color
      # sddm-apple
      sddm-kcm
      transmission-gtk
      xterm
      alacritty
      p7zip
      # unstable.alacritty
      # plasma-desktop
            # plasma-workspace
            # plasma-workspace-wallpapers
      # tokyo-night-sddm
      # sddm-theme-dialog
      # (callPackage ./themes/sddm-theme-dialog.nix {}).sddm-theme-dialog
    ];


  i18n.defaultLocale = "fr_FR.UTF-8";
  i18n.extraLocaleSettings = {
      LC_ADDRESS = "fr_FR.UTF-8";
      LC_IDENTIFICATION = "fr_FR.UTF-8";
      LC_MEASUREMENT = "fr_FR.UTF-8";
      LC_MONETARY = "fr_FR.UTF-8";
      LC_NAME = "fr_FR.UTF-8";
      LC_NUMERIC = "fr_FR.UTF-8";
      LC_PAPER = "fr_FR.UTF-8";
      LC_TELEPHONE = "fr_FR.UTF-8";
      LC_TIME = "fr_FR.UTF-8";
  };

  environment.sessionVariables = {
    # POLKIT_AUTH_AGENT = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
    # GSETTINGS_SCHEMA_DIR = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas";
    # LIBVA_DRIVER_NAME = "nvidia";
    # XDG_SESSION_TYPE = "wayland";
    # GBM_BACKEND = "nvidia-drm";
    # __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    # WLR_NO_HARDWARE_CURSORS = "1";
    # NIXOS_OZONE_WL = "1";
    # MOZ_ENABLE_WAYLAND = "1";
    # SDL_VIDEODRIVER = "wayland";
    # _JAVA_AWT_WM_NONREPARENTING = "1";
    # CLUTTER_BACKEND = "wayland";
    # WLR_RENDERER = "vulkan";
    # XDG_CURRENT_DESKTOP = "Hyprland";
    # XDG_SESSION_DESKTOP = "Hyprland";
    # GTK_USE_PORTAL = "1";
    # NIXOS_XDG_OPEN_USE_PORTAL = "1";
  };
}
