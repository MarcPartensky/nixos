# mnemo: the retention engine, one Rust binary plus the static front-end.
#
# callPackage-shaped on purpose: the NixOS module of this flake builds it
# against the nixpkgs of the importing system, so there is no second nixpkgs and
# no `--impure`.
{
  lib,
  rustPlatform,
}: let
  version = "0.1.0";
in
  rustPlatform.buildRustPackage {
    pname = "mnemo";
    inherit version;

    src = ./.;

    # Cargo.lock is committed; buildRustPackage vendors from it. rusqlite is
    # built with the `bundled` feature, so the SQLite C sources are compiled
    # here: no system sqlite to match, and the same behaviour on every host.
    cargoLock.lockFile = ./Cargo.lock;

    # reqwest uses rustls, so there is no openssl to link and no pkg-config
    # step. The schema and the browser app have no build step either: they ship
    # as they are, next to the binary.
    postInstall = ''
      mkdir -p $out/share/mnemo
      cp -r web $out/share/mnemo/web
      cp sql/schema.sql $out/share/mnemo/schema.sql
    '';

    meta = {
      description = "Score conversations, explain what was missed, feed the podcast and the typing drill";
      homepage = "https://mnemo.marcpartensky.com";
      license = lib.licenses.mit;
      mainProgram = "mnemo";
      platforms = lib.platforms.unix;
    };
  }
