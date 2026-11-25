# Rust package of the presence service (see default.nix for the module).
# Isolated from the module so it can be built alone: `nix build .#presence`.
{pkgs, ...}:
pkgs.rustPlatform.buildRustPackage {
  pname = "presence";
  version = "0.1.0";
  src = ./rust;
  # Cargo.lock contains only registry crates: importCargoLock pins them
  # by checksum, no vendorHash to maintain.
  cargoLock.lockFile = ./rust/Cargo.lock;
  cargoBuildFlags = ["--locked"];
  # SQLite from nixpkgs (reading Hermes' state.db): we link against the
  # system library rather than compiling the C amalgamation (feature
  # `bundled`), so pkg-config is the only extra build tool.
  # The Postgres client, for its part, is pure Rust: nothing to link.
  nativeBuildInputs = [pkgs.pkg-config];
  buildInputs = [pkgs.sqlite];
  # The binary embeds the page (include_str!): no file alongside.
  doCheck = false;
  meta = {
    description = "marc presence (devices, location, forecast, CPU reservation)";
    mainProgram = "presence";
  };
}
