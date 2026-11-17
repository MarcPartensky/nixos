{ pkgs, lib, ... }:
# Acces root NixOS pour l'agent hermes : EVAL PURE UNIQUEMENT, un rebuild a la
# fois.
#
# Pourquoi ce module existe (14/11/2026) : la regle sudo NOPASSWD portait sur
# nixos-rebuild SANS restriction d'arguments. Un script non interactif (le cron
# watchdog atlas-redeploy.sh) a donc pu passer --impure et relancer des switches
# impurs, concurrents du switch pur en cours ; deux activations simultanees
# repassent /etc/passwd en 600 et cassent les lookups NSS.
#
# Le filtrage par arguments dans sudoers ne marche pas : le `*` d'une regle
# avale aussi `--impure`. La seule forme sure est une commande dediee qui
# inspecte ses arguments : hermes n'a plus le droit d'appeler nixos-rebuild
# directement, uniquement ce wrapper.
#
# Ce que le wrapper garantit :
#   - `--impure` est refuse (rc 97). NixOS ne s'evalue qu'en pur ici.
#   - les rebuilds sont serialises par flock (attente max 1 h, rc 98 au dela),
#     verrou partage avec ~/.bashrc de hermes et les scripts de deploiement.
#   - le reste passe tel quel a nixos-rebuild (/run/current-system).
#
# Les projets personnels (flakes hors NixOS) gardent --impure : ce verrou ne
# couvre que nixos-rebuild, pas `nix build --impure` sur un projet perso.
#
# marc garde son acces direct : il est proprietaire de la machine.
let
  lock = "/var/lib/hermes/.hermes/state/nixos-rebuild.lock";
  gated = pkgs.writeShellScriptBin "nixos-rebuild-gated" ''
    set -u
    lock="''${NIXOS_REBUILD_LOCK:-${lock}}"
    for a in "$@"; do
      case "$a" in
        --impure|--impure=*)
          printf 'REFUS: NixOS ne s evalue qu en PUR (politique marc, 13/11/2026).\n' >&2
          printf 'Retire --impure : tower est pur depuis que infra-atlas est un input verrouille.\n' >&2
          exit 97
          ;;
      esac
    done
    mkdir -p "$(dirname "$lock")" 2>/dev/null || true
    exec 9>>"$lock" || exit 99
    chmod 0666 "$lock" 2>/dev/null || true
    if ! flock -w 3600 9; then
      printf 'REFUS: un autre rebuild tient %s depuis plus d une heure.\n' "$lock" >&2
      exit 98
    fi
    exec /run/current-system/sw/bin/nixos-rebuild "$@"
  '';
in
{
  environment.systemPackages = [ gated ];

  security.sudo.extraRules = [
    {
      users = [ "hermes" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild-gated";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/nix/store/*-nixos-rebuild-gated/bin/nixos-rebuild-gated";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
