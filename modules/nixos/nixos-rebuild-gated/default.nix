{ config, pkgs, lib, ... }:
# NixOS root access for the hermes agent: PURE EVAL ONLY, one rebuild at a
# time, and NO compilation on tower.
#
# Why this module exists (14/11/2026): the sudo NOPASSWD rule applied to
# nixos-rebuild WITHOUT argument restriction. A non-interactive script (the cron
# watchdog atlas-redeploy.sh) could therefore pass --impure and relaunch impure
# switches, concurrent with the pure switch in progress; two simultaneous activations
# reset /etc/passwd to 600 and break the NSS lookups.
#
# Argument filtering in sudoers does not work: the `*` of a rule
# also swallows `--impure`. The only safe form is a dedicated command that
# inspects its arguments: hermes is no longer allowed to call nixos-rebuild
# directly, only this wrapper.
#
# What the wrapper guarantees:
#   - `--impure` is refused (rc 97). NixOS only evaluates in pure mode here.
#   - rebuilds are serialized by flock (wait max 1 h, rc 98 beyond that),
#     lock shared with hermes's ~/.bashrc and the deployment scripts.
#   - on tower, `--builders` is ALWAYS injected (chosen by load via
#     nix-builders-pick, cf. builders-pick.sh): the build jobs go to
#     the laptop or the deck, never to marc's CPU. Without a reachable builder the
#     switch fails (rc 96) instead of compiling locally; `--local-build` (or
#     NIXOS_ALLOW_LOCAL_BUILD=1) forces a bounded fallback of 1 job / 1 core.
#   - the rest passes as-is to nixos-rebuild (/run/current-system).
#
# Personal projects (flakes outside NixOS) keep --impure: this lock only
# covers nixos-rebuild, not `nix build --impure` on a personal project.
#
# marc keeps his direct access: he owns the machine.
let
  lock = "/var/lib/hermes/.hermes/state/nixos-rebuild.lock";

  # Chooses the remote builders by load (laptop/deck) and prints the value
  # to pass to `nix --builders`. Exposed on the PATH (systemPackages) so that the
  # Justfile `build` and the scripts also use it.
  builders-pick = pkgs.writeShellApplication {
    name = "nix-builders-pick";
    runtimeInputs = [ pkgs.openssh pkgs.coreutils pkgs.gnused pkgs.gawk ];
    text = builtins.readFile ./builders-pick.sh;
  };

  # tower is marc's interactive machine: it does not compile.
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
          printf 'REFUSED: NixOS only evaluates in PURE mode (marc policy, 13/11/2026).\n' >&2
          printf 'Remove --impure: tower is pure since infra-atlas is a locked input.\n' >&2
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
            action=""; have_builders=0; have_maxjobs=0
            for a in "$@"; do
              case "$a" in
                --builders|--builders=*) have_builders=1 ;;
                --max-jobs|--max-jobs=*) have_maxjobs=1 ;;
                switch|boot|test|build|dry-build|dry-activate) action="$a" ;;
              esac
            done
            if [ -n "$action" ] && [ "$have_builders" = 0 ]; then
              # nix-builders-pick logs its probe (headroom, RAM) to stderr: we
              # let it through and only capture the spec on stdout. Store path
              # hardcoded: sudo may restrict the PATH (secure_path).
              spec="$(${builders-pick}/bin/nix-builders-pick || true)"
              if [ -n "$spec" ]; then
                printf 'nixos-rebuild-gated: builders = %s\n' "$spec" >&2
                set -- "$@" --builders "$spec"
                # Do NOT add --max-jobs 0 here. In Nix 2.34 it disables remote
                # builds too ("Cannot build ... Reason: local builds are
                # disabled (max-jobs = 0)"), so every build fails instead of
                # going to the builder. The guard against silent local compiles
                # is the reachability check below (rc 96) plus builders-first
                # scheduling: a builder that dies mid-build can still make nix
                # recompile locally, so watch the log for "building ... on".
              else
                printf 'REFUSED: no reachable builder (laptop, deck): tower does not compile\n' >&2
                printf "for the agent (marc policy, 25/11/2026). Retry when a builder\n" >&2
                printf 'answers, or force a bounded local fallback with --local-build.\n' >&2
                exit 96
              fi
            fi
          else
            printf 'nixos-rebuild-gated: --local-build: bounded local fallback (1 job, 1 core)\n' >&2
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
      printf 'REFUSED: another rebuild has held %s for more than an hour.\n' "$lock" >&2
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
