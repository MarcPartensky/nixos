# Client YouTube Music TUI "Yututui" (commande ytt, github:Ochichan/Yututui).
# Streaming sans login Google, daemon + MPRIS.
{pkgs, inputs, ...}: let
  # doCheck = false : les 11 tests unitaires sync/data_export de 1.7.6 échouent
  # dans le sandbox de build nix (permissions FS / écritures atomiques), alors
  # que 4849 autres passent. La compilation et l'installation sont saines.
  yututui = inputs.yututui.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (_: {
    doCheck = false;
  });
in {
  home.packages = [yututui];
}
