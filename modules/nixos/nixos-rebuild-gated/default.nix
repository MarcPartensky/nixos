{ config, pkgs, lib, ... }:
# Acces root NixOS pour l'agent hermes : EVAL PURE UNIQUEMENT, un rebuild a la
# fois, et AUCUNE compilation sur tower.
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
#   - sur tower, `--builders` est TOUJOURS injecte (choisi par charge via
#     nix-builders-pick, cf. builders-pick.sh) : les jobs de build partent sur
#     le laptop ou le deck, jamais sur le CPU de marc. Sans builder joignable le
#     switch echoue (rc 96) au lieu de compiler en local ; `--local-build` (ou
#     NIXOS_ALLOW_LOCAL_BUILD=1) force un repli borne a 1 job / 1 coeur.
#   - le reste passe tel quel a nixos-rebuild (/run/current-system).
#
# Les projets personnels (flakes hors NixOS) gardent --impure : ce verrou ne
# couvre que nixos-rebuild, pas `nix build --impure` sur un projet perso.
#
# marc garde son acces direct : il est proprietaire de la machine.
let
  lock = "/var/lib/hermes/.hermes/state/nixos-rebuild.lock";

  # Choisit les builders distants par charge (laptop/deck) et affiche la valeur
  # a passer a `nix --builders`. Expose sur le PATH (systemPackages) pour que le
  # Justfile `build` et les scripts s'en servent aussi.
  builders-pick = pkgs.writeShellApplication {
    name = "nix-builders-pick";
    runtimeInputs = [ pkgs.openssh pkgs.coreutils pkgs.gnused pkgs.gawk ];
    text = builtins.readFile ./builders-pick.sh;
  };

  # tower est la machine interactive de marc : elle ne compile pas.
  offload = config.networking.hostName == "tower";

  gated = pkgs.writeShellScriptBin "nixos-rebuild-gated" ''
    set -u
    lock="''${NIXOS_REBUILD_LOCK:-${lock}}"
    allow_local=0
    if [ -n "''${NIXOS_ALLOW_LOCAL_BUILD:-}" ]; then allow_local=1; fi
    args=()
    for a in "$@"; do
      case "$a" in
        --impure|--impure=*)
          printf 'REFUS: NixOS ne s evalue qu en PUR (politique marc, 13/11/2026).\n' >&2
          printf 'Retire --impure : tower est pur depuis que infra-atlas est un input verrouille.\n' >&2
          exit 97
          ;;
        --local-build)
          allow_local=1
          ;;
        *)
          args+=("$a")
          ;;
      esac
    done
    set -- "''${args[@]}"

    ${
      if offload then
        ''
          if [ "$allow_local" = 0 ]; then
            action=""; have_builders=0
            for a in "$@"; do
              case "$a" in
                --builders|--builders=*) have_builders=1 ;;
                switch|boot|test|build|dry-build|dry-activate) action="$a" ;;
              esac
            done
            if [ -n "$action" ] && [ "$have_builders" = 0 ]; then
              # nix-builders-pick logue sa sonde (headroom, RAM) sur stderr :
              # on la laisse filer, on ne capture que la spec sur stdout. Chemin
              # du store en dur : sudo peut restreindre le PATH (secure_path).
              spec="$(${builders-pick}/bin/nix-builders-pick || true)"
              if [ -n "$spec" ]; then
                printf 'nixos-rebuild-gated: builders = %s\n' "$spec" >&2
                set -- "$@" --builders "$spec"
              else
                printf 'REFUS: aucun builder joignable (laptop, deck) : tower ne compile pas\n' >&2
                printf "pour l'agent (politique marc, 25/11/2026). Reessaie quand un builder\n" >&2
                printf 'repond, ou force un repli local borne avec --local-build.\n' >&2
                exit 96
              fi
            fi
          else
            printf 'nixos-rebuild-gated: --local-build : repli local borne (1 job, 1 coeur)\n' >&2
            set -- "$@" --max-jobs 1 --cores 1
          fi
        ''
      else
        ""
    }

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
  environment.systemPackages = [ gated builders-pick ];

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
