# typer: `typer-server` (static front-end + WebSocket race rooms) and
# `typer-race` (terminal client), built from the Cargo workspace at the root of
# this repo.
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
    pname = "typer";
    inherit version;

    src = ./.;

    # Cargo.lock is committed; buildRustPackage vendors from it.
    cargoLock.lockFile = ./Cargo.lock;

    # `cargo build --release` at the workspace root builds both crates;
    # cargoInstallHook copies the executables into $out/bin. The browser app has
    # no build step, so it ships as-is next to them.
    postInstall = ''
      mkdir -p $out/share/typer
      cp -r web $out/share/typer/web
    '';

    meta = {
      description = "Typing drills in the browser and private race rooms";
      homepage = "https://typer.marcpartensky.com";
      license = lib.licenses.mit;
      mainProgram = "typer-server";
      platforms = lib.platforms.unix;
    };
  }
