{pkgs, ...}: let
  deep-filter-cli = pkgs.rustPlatform.buildRustPackage {
    pname = "deep-filter-cli";
    version = pkgs.deepfilternet.version;

    src = pkgs.deepfilternet.src;

    # On met le hash exact que Nix vient de nous donner !
    cargoHash = "sha256-eNyX2ir+JYV15QI+e8tWcso7DVEbPxcS6PKenJIPzEA=";

    cargoBuildFlags = ["-p" "deep_filter"];

    nativeBuildInputs = [
      pkgs.pkg-config
      pkgs.python3
    ];

    buildInputs = [
      pkgs.hdf5
      pkgs.hdf5.dev
      pkgs.alsa-lib
    ];

    HDF5_DIR = "${pkgs.symlinkJoin {
      name = "hdf5-merged";
      paths = [pkgs.hdf5 pkgs.hdf5.dev];
    }}";

    doCheck = false;
  };
in {
  home.packages = [
    deep-filter-cli
  ];
}
