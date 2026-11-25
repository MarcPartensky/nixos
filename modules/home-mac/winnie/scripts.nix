# Winnie build commands for macOS, as writeShellApplication derivations:
# shellcheck runs at build and each command is versioned with the config.
#
# Separated from the home-manager module on purpose: this file is imported as-is from
# tower with the x86_64-linux pkgs to build and test the same scripts
# without a Mac (the Mac rebuilds them with its darwin pkgs).
{
  pkgs,
  lib,
  cfg, # { repoRel, towerRepo, towerHosts, apiUrl }
}:
let
  subst = text:
    lib.replaceStrings
    ["@REPO_REL@" "@TOWER_REPO@" "@TOWER_HOSTS@" "@API_URL@" "@WINNIE_SYNC@"]
    [
      cfg.repoRel
      cfg.towerRepo
      (lib.concatMapStrings (h: "'${h}' ") cfg.towerHosts)
      cfg.apiUrl
      (lib.getExe sync)
    ]
    text;

  # Scripts executed INSIDE the winnie flake devShell: their tools (npm, cargo,
  # tauri, xcrun, simctl) come from this shell, hence empty runtimeInputs.
  inner = name: file: pkgs.writeShellApplication {
    name = "winnie-${name}-inner";
    text = subst (builtins.readFile file);
  };

  # Exposed commands: cd into the repo then re-execution of the inner in
  # `nix develop`, so that nothing depends on the Mac's PATH.
  dev = name: innerScript: pkgs.writeShellApplication {
    name = "winnie-${name}";
    runtimeInputs = [pkgs.nix];
    text = ''
      repo="$HOME/${cfg.repoRel}"
      if [ ! -f "$repo/flake.nix" ]; then
        echo "winnie-${name}: repo missing ($repo). Run winnie-sync." >&2
        exit 1
      fi
      cd "$repo"
      exec nix --extra-experimental-features 'nix-command flakes' develop -c ${lib.getExe innerScript} "$@"
    '';
  };

  # Refreshes the repo from tower: rsync of tower's local repo (the repo
  # has no git remote, tower is the only original).
  sync = pkgs.writeShellApplication {
    name = "winnie-sync";
    runtimeInputs = [pkgs.rsync pkgs.openssh];
    text = subst (builtins.readFile ./scripts/sync.sh);
  };

  # Machine state: Xcode, iOS SDK, simulator runtime, node_modules, API.
  # Xcode is not in the Nix store (App Store), so this diagnostic is the
  # only source of truth, and --fix automates everything except installing Xcode.
  doctor = pkgs.writeShellApplication {
    name = "winnie-doctor";
    runtimeInputs = [pkgs.nix pkgs.curl pkgs.coreutils];
    text = subst (builtins.readFile ./scripts/doctor.sh);
  };

  # Interactive project DevShell, without guessing the repo path.
  shell = pkgs.writeShellApplication {
    name = "winnie-shell";
    runtimeInputs = [pkgs.nix];
    text = ''
      repo="$HOME/${cfg.repoRel}"
      if [ ! -f "$repo/flake.nix" ]; then
        echo "winnie-shell: repo missing ($repo). Run winnie-sync." >&2
        exit 1
      fi
      cd "$repo"
      exec nix --extra-experimental-features 'nix-command flakes' develop "$@"
    '';
  };
in {
  inherit doctor shell sync;

  # Vite server (HMR) of the Svelte front.
  front = dev "front" (inner "front" ./scripts/front.sh);

  # Tauri app: macOS (CLT enough) and iOS (Xcode required).
  macos = dev "macos" (inner "macos" ./scripts/macos-dev.sh);
  macos-build = dev "build-macos" (inner "build-macos" ./scripts/macos-build.sh);
  ios = dev "ios" (inner "ios" ./scripts/ios-dev.sh);
  ios-build = dev "build-ios" (inner "build-ios" ./scripts/ios-build.sh);

  # Pre-commit checks (front + svelte-check + cargo check).
  verify = dev "verify" (inner "verify" ./scripts/verify.sh);
}
