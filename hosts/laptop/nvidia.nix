{ config, lib, pkgs, ... }:
{
  # nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
  #   "nvidia-x11"
  #   "nvidia-settings"
  # ];

  # Essential OpenGL configuration
  hardware.opengl = {
    enable = true;
    # driSupport = true;
    # driSupport32Bit = true;
    extraPackages = with pkgs; [ 
      vaapiVdpau
      libvdpau-va-gl
      nvidia-vaapi-driver
    ];
  };

  # Load nvidia driver
  services.xserver.videoDrivers = ["nvidia"];
  boot.kernelModules = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = false;
    open = false;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # PRIME configuration - NVIDIA as primary GPU
    prime = {
      offload.enable = false;  # Disable offloading to force NVIDIA as primary
      # Bus IDs from lspci output:
      #   00:02.0 -> "PCI:0:2:0"
      #   01:00.0 -> "PCI:1:0:0"
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  # Environment variables for proper GPU acceleration
  environment.sessionVariables = {
    GBM_BACKEND = "nvidia-drm";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    LIBVA_DRIVER_NAME = "nvidia";
    WLR_NO_HARDWARE_CURSORS = "1";  # Fixes cursor issues in Wayland
  };

  # Xorg server configuration (still required for some Wayland features)
  services.xserver.config = ''
    Section "OutputClass"
        Identifier "nvidia"
        MatchDriver "nvidia-drm"
        Driver "nvidia"
        Option "AllowEmptyInitialConfiguration"
        Option "PrimaryGPU" "true"
    EndSection
  '';
}
