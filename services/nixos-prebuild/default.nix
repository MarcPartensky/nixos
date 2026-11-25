# Prébuild asynchrone de la config tower : dès que HEAD ou le diff des
# fichiers suivis change, on pose une tâche taskq `nixos-rebuild build`.
# `just nixos` ne fait alors plus que l'activation, et le post-build-hook
# d'attic (services/attic) pousse les paquets fraîchement compilés dans la
# cache binaire locale au passage.
#
# Le timer ne fait QUE poser la tâche (clé d'idempotence = empreinte, une
# seule ligne taskq par état de l'arbre) ; le dispatcher la lance quand la
# machine le permet (classe light, --while-busy : elle doit tourner pendant
# que marc travaille, c'est le but).
{ config, pkgs, ... }:
let
  repo = "/home/marc/git/nixos";
in
{
  systemd.services.nixos-prebuild-check = {
    description = "Pose un prébuild taskq si la config nixos (tower) a changé";
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
