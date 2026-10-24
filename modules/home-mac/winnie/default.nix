# Environnement de build de l'app Winnie sur le Mac (front Svelte 5 + shell
# Tauri), pour que builder soit une commande, pas une procédure.
#
# Le toolchain (rust + triples iOS, node 22, cocoapods, tauri-cli, postgres) vit
# dans le devShell du flake `winnie` : ce module ne fait qu'exposer les
# commandes qui l'utilisent, chacune re-rentrant dans `nix develop`.
#   winnie-doctor        état du poste (Xcode, simulateur, dépôt, API) ; --fix
#   winnie-sync          rafraîchit ~/git/winnie depuis tower (LAN ou rack)
#   winnie-shell         devShell interactif
#   winnie-front         serveur Vite (HMR)
#   winnie-macos         app macOS en dev ; winnie-build-macos = .app/.dmg
#   winnie-ios           app iOS dans le simulateur ; winnie-build-ios = archive
#   winnie-verify        front + svelte-check + cargo check
#
# Ce qui reste manuel, forcément : Xcode (App Store, Apple en interdit la
# redistribution), le runtime du simulateur (winnie-doctor --fix le télécharge)
# et un compte Apple pour signer un build pour iPhone réel.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.my.winnie;
in {
  options.my.winnie = {
    enable = lib.mkEnableOption "l'environnement de build Winnie sur macOS";

    repoRel = lib.mkOption {
      type = lib.types.str;
      default = "git/winnie";
      description = "Chemin du dépôt winnie, relatif à $HOME.";
    };

    towerRepo = lib.mkOption {
      type = lib.types.str;
      default = "/home/marc/git/winnie";
      description = "Chemin du même dépôt sur tower, source de winnie-sync (pas de remote git).";
    };

    towerHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["towerlocal" "tower"];
      description = ''
        Alias ssh essayés dans l'ordre par winnie-sync : le LAN d'abord
        (towerlocal = 192.168.1.44), puis le tunnel par le VPS
        (tower = 10.100.0.3 via rack, tenu par l'agent autossh du Mac).
      '';
    };

    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://api.winnie.marcpartensky.com";
      description = "API interrogée par winnie-doctor et par le front.";
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
