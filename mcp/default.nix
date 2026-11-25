# mcp/default.nix
# The home-grown MCP servers, exposed as flake outputs.
#
# Why: today each server is built in the module of the service
# that declares it, so it can only exist in the closure of
# nixosConfigurations.tower, and only after a full host eval.
# Here each server is an independent package: `nix build .#shlink-mcp`
# evaluates only nixpkgs and this file, not the NixOS config.
#
# What it does not do yet: the module-side wiring. As long as
# services/<name>/default.nix defines its binary locally, the host does not consume
# these outputs. The switch happens module by module, by pointing
# `command = "${self.packages.${pkgs.system}.<name>}/bin/<name>"`.
#
# Servers deliberately absent: those whose python code is still an
# inline string in the module (androidtv-mcp, roku-mcp, pangolin-mcp, tts-mcp).
# Moving them out requires first extracting the code into a .py alongside.
{pkgs}: let
  py = pkgs.python3Packages;
  mk = name: file: libraries:
    pkgs.writers.writePython3Bin name {
      inherit libraries;
      flakeIgnore = ["E501" "W503" "W504"];
    } (builtins.readFile file);
in {
  # Rust port of the shlink MCP server (crate in ./shlink-mcp-rs).
  # Measurement of 15/11/2026, same API, same 10 tools: 1.4 MB of RSS instead of
  # 54, 2 ms of startup instead of 4200, and the text rendered to the model is
  # compact JSON (1.4 kB instead of 2.4 kB on a list). Cargo.lock is
  # locked in the repo, so the build is reproducible without network
  # beyond fetching the crates of the lockfile.
  shlink-mcp = pkgs.rustPlatform.buildRustPackage {
    pname = "shlink-mcp-rs";
    version = "0.1.0";
    src = ./shlink-mcp-rs;
    cargoLock.lockFile = ./shlink-mcp-rs/Cargo.lock;
    meta = {
      description = "Shlink MCP server in Rust (stdio, 10 tools)";
      mainProgram = "shlink-mcp-rs";
    };
  };
  shorturl-mcp = mk "shorturl-mcp" ../services/shorturl-mcp/server.py [py.mcp];
  beef-mcp = mk "beef-mcp" ../services/beef-mcp/server.py [py.mcp];
  share-mcp = mk "share-mcp" ../services/share-mcp/server.py [py.mcp];
  meetup-mcp = mk "meetup-mcp" ../services/meetup-mcp/meetup_mcp.py [py.mcp];
  mac-mcp = mk "mac-mcp" ../services/mac-mcp/mac-mcp.py [py.mcp];
  ibkr-mcp = mk "ibkr-mcp" ../services/ibkr-mcp/ibkr_flex.py [py.mcp];
  arena-elo-mcp = mk "arena-elo-mcp" ../services/arena-elo-mcp/arena-elo.py [];
  username-recon = mk "username-recon" ../services/sherlock-mcp/server.py [];
}
