# YouTube Music TUI client "Yututui" (command ytt, github:Ochichan/Yututui).
# Streaming without Google login, daemon + MPRIS.
{pkgs, inputs, ...}: let
  # doCheck = false: the 11 sync/data_export unit tests of 1.7.6 fail
  # in the nix build sandbox (FS permissions / atomic writes), while
  # 4849 others pass. The compilation and installation are sound.
  yututui = inputs.yututui.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (_: {
    doCheck = false;
  });
in {
  home.packages = [yututui];
}
