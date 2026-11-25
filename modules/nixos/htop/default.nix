# htop: columns and screens shared across the fleet, oriented toward CPU/RAM diagnostics
# (see htoprc alongside for the details of the four screens).
#
# /etc/htoprc is htop's last resort: it is only read by a
# user who has no ~/.config/htop/htoprc. It is therefore the config of
# root (sudo htop on tower, or direct root) and of new accounts. Marc has the
# same file directly linked via users/marc/home.nix.
{pkgs, ...}: {
  environment.etc."htoprc".source = ./htoprc;
  environment.systemPackages = [pkgs.htop];
}
