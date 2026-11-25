# typer: typing drills in the browser, race rooms you join with a link.
#
# The whole runtime is the Cargo workspace at the root of this repo: one Rust
# server for the static front-end and the WebSocket rooms, one terminal client.
# The flake is standalone (`nix build .#`, `nix develop`) and also exports
# `nixosModules.default` so the system flake can deploy it.
#
# Consumed by the system flake as a LOCKED path input (pure eval), from a copy
# vendored under projects/typer of that repo: one absolute path cannot resolve
# on both tower (Linux) and the Mac (macOS).
#
#   typer = { url = "path:./projects/typer"; inputs.nixpkgs.follows = "nixpkgs"; };
#
# A write to that copy needs `git add` first (nix ignores untracked files of a
# git flake), then `nix flake lock` in the system flake. Path inputs are copied
# fresh on every eval, so no commit is required to see a change.
{
  description = "typer: typing drills and race rooms (Rust server, TUI client, no build step front-end)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    forAllSystems = f:
      nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    packages = forAllSystems (pkgs: {
      typer = pkgs.callPackage ./package.nix {};
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.typer;
    });

    nixosModules.default = import ./module.nix;
    nixosModules.typer = self.nixosModules.default;

    # home-manager module: writes the typer-race client config file. Consumed
    # by users/mac/home.nix (`inputs.typer.homeManagerModules.default`).
    homeManagerModules.default = import ./home-module.nix;
    homeManagerModules.typer = self.homeManagerModules.default;

    checks = forAllSystems (pkgs: {
      inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) typer;
    });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = with pkgs; [
          cargo
          rustc
          rust-analyzer
          clippy
          rustfmt
          nodejs # `node --check web/*.js`
          python3 # legacy reference server, see legacy/
        ];
        RUST_BACKTRACE = "1";
      };
    });

    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
