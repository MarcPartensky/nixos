# Commandes de build Winnie pour macOS, en dérivations writeShellApplication :
# shellcheck tourne au build et chaque commande est versionnée avec la config.
#
# Séparé du module home-manager exprès : ce fichier s'importe tel quel depuis
# tower avec les pkgs x86_64-linux pour construire et tester les mêmes scripts
# sans Mac (le Mac les reconstruit avec ses pkgs darwin).
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

  # Scripts exécutés DANS le devShell du flake winnie : leurs outils (npm, cargo,
  # tauri, xcrun, simctl) viennent de ce shell, d'où runtimeInputs vide.
  inner = name: file: pkgs.writeShellApplication {
    name = "winnie-${name}-inner";
    text = subst (builtins.readFile file);
  };

  # Commandes exposées : cd dans le dépôt puis ré-exécution de l'inner dans
  # `nix develop`, pour que rien ne dépende du PATH du Mac.
  dev = name: innerScript: pkgs.writeShellApplication {
    name = "winnie-${name}";
    runtimeInputs = [pkgs.nix];
    text = ''
      repo="$HOME/${cfg.repoRel}"
      if [ ! -f "$repo/flake.nix" ]; then
        echo "winnie-${name} : dépôt absent ($repo). Lance winnie-sync." >&2
        exit 1
      fi
      cd "$repo"
      exec nix --extra-experimental-features 'nix-command flakes' develop -c ${lib.getExe innerScript} "$@"
    '';
  };

  # Rafraîchit le dépôt depuis tower : rsync du dépôt local de tower (le dépôt
  # n'a pas de remote git, tower est le seul original).
  sync = pkgs.writeShellApplication {
    name = "winnie-sync";
    runtimeInputs = [pkgs.rsync pkgs.openssh];
    text = subst (builtins.readFile ./scripts/sync.sh);
  };

  # État du poste : Xcode, SDK iOS, runtime du simulateur, node_modules, API.
  # Xcode n'est pas dans le store Nix (App Store), donc ce diagnostic est la
  # seule source de vérité, et --fix automatise tout sauf l'installation d'Xcode.
  doctor = pkgs.writeShellApplication {
    name = "winnie-doctor";
    runtimeInputs = [pkgs.nix pkgs.curl pkgs.coreutils];
    text = subst (builtins.readFile ./scripts/doctor.sh);
  };

  # DevShell interactif du projet, sans deviner le chemin du dépôt.
  shell = pkgs.writeShellApplication {
    name = "winnie-shell";
    runtimeInputs = [pkgs.nix];
    text = ''
      repo="$HOME/${cfg.repoRel}"
      if [ ! -f "$repo/flake.nix" ]; then
        echo "winnie-shell : dépôt absent ($repo). Lance winnie-sync." >&2
        exit 1
      fi
      cd "$repo"
      exec nix --extra-experimental-features 'nix-command flakes' develop "$@"
    '';
  };
in {
  inherit doctor shell sync;

  # Serveur Vite (HMR) du front Svelte.
  front = dev "front" (inner "front" ./scripts/front.sh);

  # App Tauri : macOS (CLT suffisent) et iOS (Xcode requis).
  macos = dev "macos" (inner "macos" ./scripts/macos-dev.sh);
  macos-build = dev "build-macos" (inner "build-macos" ./scripts/macos-build.sh);
  ios = dev "ios" (inner "ios" ./scripts/ios-dev.sh);
  ios-build = dev "build-ios" (inner "build-ios" ./scripts/ios-build.sh);

  # Contrôles avant commit (front + svelte-check + cargo check).
  verify = dev "verify" (inner "verify" ./scripts/verify.sh);
}
