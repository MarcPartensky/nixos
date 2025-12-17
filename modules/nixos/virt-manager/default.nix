{ pkgs, ... }: {

  # programs.virt-manager.enable = true;
  virtualisation.libvirtd.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;

  # specific to marc user
  users.groups.libvirtd.members = ["marc"];
  users.users.marc.extraGroups = [ "libvirtd" ];

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;  # enable copy and paste between host and guest
}
