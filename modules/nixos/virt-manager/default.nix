{ pkgs, ... }: {

  virtualisation.spiceUSBRedirection.enable = true;

  virtualisation.libvirtd.enable = true;
  security.polkit.enable = true;

  # specific to marc user
  # users.groups.libvirtd.members = ["marc"];
  users.users.marc.extraGroups = [
    "libvirtd"
    "kvm"
  ];

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;  # enable copy and paste between host and guest
}
