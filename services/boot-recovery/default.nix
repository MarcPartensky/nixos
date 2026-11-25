{
  config,
  lib,
  pkgs,
  ...
}:

# Recovery of critical units left not started after a boot.
#
# THE PROBLEM, measured on 17/11/2026: `Restart=` does NOT cover the failure of a
# dependency. When postgresql.service exceeded its TimeoutStartSec (WAL
# recovery after an unclean shutdown), systemd failed in cascade all the
# `Requires=postgresql.*`: matrix-synapse-db, matrix-synapse, immich-server,
# immich-machine-learning. These units are NOT "failed" in the sense of
# `systemctl --failed` (they stay `inactive (dead)` with a simple
# "Job ... failed with result 'dependency'" in the journal), and systemd does not
# schedule any restart: the service stays dead until an intervention.
# Result that day: matrix in 503 for 5 h, immich and attic with it, whereas
# postgres had come back 15 s later.
#
# The root cause is handled at the source (services/postgres: TimeoutStartSec
# at 15 min). This module is the second layer: it covers ALL the other
# races of the same kind (atticd not listening yet, API not ready, cascade
# of another dependency), without having to guess the cause.
#
# Scope deliberately bounded: units listed explicitly, only within
# the `windowMinutes` that follow startup, with a capped number of attempts
# per unit. Past this window, a stopped service is up to
# `Restart=` or a human decision, not a silent recovery.

let
  cfg = config.services.bootRecovery;

  recover = pkgs.writeShellScript "boot-recovery" ''
    set -u
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.systemd
      ]
    }:/run/current-system/sw/bin:/run/wrappers/bin

    up=$(cut -d. -f1 /proc/uptime)
    if [ "$up" -gt ${
      toString (cfg.windowMinutes * 60)
    } ]; then
      echo "startup window passed (uptime ''${up}s), nothing to do"
      exit 0
    fi

    state=/run/boot-recovery
    mkdir -p "$state"

    for u in ${lib.escapeShellArgs cfg.units}; do
      st=$(systemctl show "$u" -p ActiveState --value 2>/dev/null || echo unknown)
      load=$(systemctl show "$u" -p LoadState --value 2>/dev/null || echo unknown)
      # Unit renamed or removed: the list is stale, say it once
      # instead of attempting a start that cannot succeed.
      if [ "$load" = "not-found" ]; then
        echo "$u does not exist (unit renamed or removed?): fix it in services.bootRecovery.units"
        continue
      fi
      case "$st" in
        active|activating|reloading|unknown)
          continue
          ;;
      esac

      n=0
      [ -f "$state/$u" ] && n=$(cat "$state/$u" 2>/dev/null || echo 0)
      if [ "$n" -ge ${toString cfg.maxAttempts} ]; then
        echo "$u inactive ($st) after $n attempts, giving up (see journalctl -u $u)"
        continue
      fi

      echo "$u inactive ($st) -> restarting, attempt $((n + 1))/${toString cfg.maxAttempts}"
      systemctl reset-failed "$u" 2>/dev/null || true
      # A failure is logged here; the timer will run again.
      systemctl start "$u" 2>&1 || true
      echo $((n + 1)) >"$state/$u"
      echo "$u -> $(systemctl is-active "$u" 2>/dev/null)"
    done
  '';
in
{
  options.services.bootRecovery = {
    enable = lib.mkEnableOption "recovery of critical units not started after boot";

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # The trio that went down on 17/11/2026. atticd-bootstrap is a oneshot
        # with RemainAfterExit: it stays `active` when it succeeded, so it does not
        # enter a restart loop.
        "matrix-synapse.service"
        "immich-server.service"
        "immich-machine-learning.service"
        "atticd-bootstrap.service"
      ];
      description = ''
        Long units (or oneshot RemainAfterExit) that must be active
        after startup. Do NOT put a transient oneshot unit there: it
        becomes `inactive (dead)` after a success and would be restarted on every round.
      '';
    };

    windowMinutes = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "Duration after boot during which the recovery acts.";
    };

    intervalMinutes = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Interval between two recovery rounds.";
    };

    maxAttempts = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "Number of restarts per unit and per boot before giving up.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.boot-recovery = {
      description = "Recovery of critical units not started (boot races)";
      # No hard dependency: the point is precisely to run when a
      # dependency has failed. After= only, never Requires=.
      after = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = recover;
        # A round with nothing to do must be a success; a round that restarted
        # something too. Failures are in the unit's journal.
        SuccessExitStatus = "0 1";
        # A recovery unit must never stay in `failed`: that would be
        # the opposite signal from the one we want to give.
        Restart = "no";
      };
    };

    systemd.timers.boot-recovery = {
      description = "Timer of the recovery of critical units after boot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        # Oneshot: we key off the end of the previous round, not off its
        # activation (OnUnitActiveSec would not re-trigger).
        OnUnitInactiveSec = "${toString cfg.intervalMinutes}min";
        AccuracySec = "30s";
        Unit = "boot-recovery.service";
      };
    };
  };
}
