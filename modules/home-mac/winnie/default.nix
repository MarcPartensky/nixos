# Build environment for the Winnie app on the Mac (Svelte 5 frontend + shell
# Tauri), so that building is a command, not a procedure.
#
# The toolchain (rust + iOS triples, node 22, cocoapods, tauri-cli, postgres) lives
# in the devShell of the `winnie` flake: this module only exposes the
# commands that use it, each re-entering `nix develop`.
#   winnie-doctor        machine state (Xcode, simulator, repo, API); --fix
#   winnie-sync          refreshes ~/git/winnie from tower (LAN or rack)
#   winnie-shell         interactive devShell
#   winnie-front         Vite server (HMR)
#   winnie-macos         macOS app in dev; winnie-build-macos = .app/.dmg
#   winnie-ios           iOS app in the simulator; winnie-build-ios = archive
#   winnie-verify        front + svelte-check + cargo check
#
# What necessarily remains manual: Xcode (App Store, Apple forbids
# redistribution), the simulator runtime (winnie-doctor --fix downloads it)
# and an Apple account to sign a build for a real iPhone.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.my.winnie;
in {
  options.my.winnie = {
    enable = lib.mkEnableOption "the Winnie build environment on macOS";

    repoRel = lib.mkOption {
      type = lib.types.str;
      default = "git/winnie";
      description = "Path of the winnie repo, relative to $HOME.";
    };

    towerRepo = lib.mkOption {
      type = lib.types.str;
      default = "/home/marc/git/winnie";
      description = "Path of the same repo on tower, source of winnie-sync (no git remote).";
    };

    towerHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["towerlocal" "tower"];
      description = ''
        ssh aliases tried in order by winnie-sync: the LAN first
        (towerlocal = 192.168.1.44), then the tunnel through the VPS
        (tower = 10.100.0.3 via rack, kept up by the Mac's autossh agent).
      '';
    };

    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://api.winnie.marcpartensky.com";
      description = "API queried by winnie-doctor and by the frontend.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.attrValues (import ./scripts.nix {
      inherit pkgs lib;
      cfg = {
        inherit (cfg) repoRel towerRepo towerHosts apiUrl;
      };
    });
  };
}
