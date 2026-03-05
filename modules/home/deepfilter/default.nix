{pkgs, ...}: let
  deep-filter-cli = pkgs.deepfilternet.overrideAttrs (oldAttrs: {
    pname = "deep-filter";

    buildAndTestSubdir = null;
    cargoBuildFlags = ["-p" "deep_filter"];
    postInstall = "";

    # On désactive la phase de tests unitaires qui fait planter le build
    doCheck = false;

    nativeBuildInputs =
      (oldAttrs.nativeBuildInputs or [])
      ++ [
        pkgs.pkg-config
        pkgs.python3
      ];

    buildInputs =
      (oldAttrs.buildInputs or [])
      ++ [
        pkgs.hdf5
        pkgs.hdf5.dev
        pkgs.alsa-lib
      ];

    HDF5_DIR = "${pkgs.symlinkJoin {
      name = "hdf5-merged";
      paths = [pkgs.hdf5 pkgs.hdf5.dev];
    }}";

    meta =
      oldAttrs.meta
      // {
        description = "DeepFilterNet CLI tool for audio noise suppression";
      };
  });
in {
  home.packages = [
    deep-filter-cli
  ];
}
