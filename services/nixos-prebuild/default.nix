# Asynchronous prebuild of the tower config: as soon as HEAD or the diff of
# tracked files changes, we submit a taskq task `nixos-rebuild build`.
# `just nixos` then only does the activation, and the post-build-hook
# of attic (services/attic) pushes the freshly compiled packages into the
# local binary cache along the way.
#
# The timer ONLY submits the task (idempotency key = fingerprint, a single
# taskq line per tree state); the dispatcher launches it when the
# machine allows it (class light, --while-busy: it must run while
# marc is working, that is the point).
{ config, pkgs, ... }:
let
  repo = "/home/marc/git/nixos";
in
{
  systemd.services.nixos-prebuild-check = {
    description = "Submit a taskq prebuild if the nixos config (tower) changed";
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
    };
    path = [ pkgs.git pkgs.coreutils ];
    script = ''
      set -eu
      state=/var/lib/hermes/.local/state/nixos-prebuild
      mkdir -p "$state"
      fp=$( {
        git -C ${repo} rev-parse HEAD
        git -C ${repo} status --porcelain=v1 --untracked-files=no
        git -C ${repo} diff HEAD
      } | sha256sum | cut -d' ' -f1 )
      if [ "$fp" = "$(cat "$state/fp" 2>/dev/null || true)" ]; then
        exit 0
      fi
      ${config.system.path}/bin/taskq submit 'nixos-rebuild build --impure --flake .#tower' \
        --key "nixos-prebuild-$fp" \
        --workdir ${repo} --run-as hermes \
        --class light --mem 3000 --est 10 --priority 40 --while-busy \
        --by nixos-prebuild
      printf '%s' "$fp" > "$state/fp"
    '';
  };

  systemd.timers.nixos-prebuild-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
    };
  };
}
