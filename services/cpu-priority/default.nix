# CPU/IO priority of background loads, and caps for winnie jobs.
#
# Two tiers:
#  1. `background.slice` (low CPU/IO weight): batches yield to the
#     desktop and Hermes sessions under contention, without a cap when the
#     machine is free.
#  2. Declarative CPUQuota caps on the winnie jobs (the safe value) +
#     `winnie-cpu-governor` which widens them to 1200 % (except the browser jobs,
#     hard-capped at 30 % of the total) as long as the CPU pressure
#     of user.slice (marc's + Hermes sessions) stays nearly zero for
#     2 min, and closes them as soon as an interactive task waits for CPU. The
#     overrides go through `systemctl set-property --runtime` (nothing in
#     /etc, a reboot returns to the declarative values, and if the governor
#     stops we stay bounded).
#
# Measured on 25/10/2026: a dish estimated by the vision model (qwen3-vl:4b,
# winnie-calories service) took ~790 % of CPU, i.e. half of the
# 4800H, and Tctl rose to 100 degC.
{ pkgs, ... }:
{
  # Hermes desktop sessions (user hermes, uid 988): they cannot
  # enter hermes.slice (root partition cpuset: a logind session does not
  # cross the hierarchy boundary), so they run on 12 threads
  # at weight 25, on the same cpuset as marc's desktop. Measured on
  # 12/11/2026: 199 % + 18 % of a core on two desktop sessions, load 25-33.
  # A low WEIGHT does not throttle them when the machine is free; under contention marc's
  # desktop gets 4/5 of the CPU instead of 1/2. Same for IO (builds, store scans).
  # The heavy work of the agents must still be routed to taskq or a background scope.
  #
  # HARD cap added on 21/11/2026: a weight bounds NOTHING when the machine
  # is free. Measured at 01:15 that day: 4 Hermes desktop sessions brought
  # tower to 98 % (15,7 cores), Tctl 100 degC, load 27, while marc was asleep and
  # nothing else was asking for CPU (the weight is only arbitrated under
  # contention). 300 % = 3 cores for ALL Hermes sessions combined.
  # Only covers THIS slice: neither hermes.slice (gateway, cpuset 12-15), nor
  # background.slice (nix-daemon, builds) are affected; a build launched
  # by the agent goes to the daemon and stays in the background.
  systemd.slices."user-988" = {
    description = "Hermes sessions (low weight + hard cap)";
    sliceConfig = {
      CPUWeight = 25;
      IOWeight = 25;
      CPUQuota = "300%";
      # `Nice=` does not exist on a slice: a slice carries no process to
      # renice, and session scopes are forked by logind, not by the
      # user manager (user@988), so nothing would inherit it.
      # CPUWeight=25 is the cgroup equivalent of nice and it is already set;
      # it is the quota above that actually bounds the peak.
    };
  };

  # What hermes's user manager launches lives HERE: rootless
  # podman containers, `systemd-run --user` scopes, agent jobs. Measurement on
  # 14/11/2026: `immich_probe_ml` + `immich_probe_server` took 5,1 + 3,6
  # = 8,8 cores at weight 100, exactly the weight of the session scope that
  # carries the desktop backend event loop (0,38 core). The two shared
  # the same 14 threads equally: 294 event loop freezes (max 114 s) and
  # 1461 `Timed out connecting to Hermes backend` on the client side. The user
  # manager drops to 10, and it alone: the interactive session placed just
  # above keeps its weight, so a running index can no longer get
  # ahead of the event loop serving the conversation.
  # `asDropin`: user@.service is a systemd template, a full file would
  # replace it instead of completing it.
  systemd.services."user@988" = {
    overrideStrategy = "asDropin";
    # NEVER restart the user manager: it would kill everything that
    # lives under it (rootless containers, transient scopes). The weight
    # applies at its next creation, so in practice at the end of all
    # sessions or at reboot.
    restartIfChanged = false;
    serviceConfig = {
      CPUWeight = 10;
      IOWeight = 10;
    };
  };

  # Media indexers: batch by nature, never prioritized over interactive.
  # The nixpkgs module already places immich-server and immich-machine-learning in
  # system-immich.slice, we only load that slice instead of going
  # to fetch its units (avoids a value conflict on `Slice`).
  # HARD cap of 6 cores out of 16, background IO, and SOFT memory cap:
  # `MemoryHigh` throttles, `MemoryMax` would have killed the index mid-scan,
  # which is exactly what we want to avoid.
  systemd.slices.system-immich.sliceConfig = {
    CPUQuota = "600%";
    CPUWeight = 20;
    IOWeight = 20;
    MemoryHigh = "12G";
  };

  # Same caps ALSO placed on both units, and not only on the
  # slice: a property of an already-created slice only applies at its next
  # creation, so the collective cap would only have bitten at a restart
  # of immich. A UNIT property, however, applies at switch (the unit is
  # restarted because its file changed). 300 % each = the 600 % of the
  # slice, but effective within the minute.
  systemd.services.immich-server.serviceConfig = {
    CPUQuota = "300%";
    IOWeight = 20;
    MemoryHigh = "6G";
  };
  systemd.services.immich-machine-learning.serviceConfig = {
    CPUQuota = "300%";
    IOWeight = 20;
    MemoryHigh = "6G";
  };

  # Second photo indexer (outside immich), same profile, smaller cap.
  systemd.slices.media-index = {
    description = "Media indexers outside immich (photoprism)";
    sliceConfig = {
      CPUQuota = "400%";
      CPUWeight = 20;
      IOWeight = 20;
      MemoryHigh = "8G";
    };
  };
  systemd.services.photoprism.serviceConfig.Slice = "media-index.slice";

  # SSH entry point: the link without which no other exists. It
  # lived in system.slice at weight 100, with no memory floor, with the default
  # restart limit (5 failures in 10 s then DEFINITIVE `failed`, even
  # with Restart=always). Honesty: `sshd-session`, the process that actually
  # encrypts the tunnel, stays in the session scope (logind), so this
  # protection covers the accept and the survival of the listener, not the tunnel throughput.
  systemd.slices.interactive = {
    description = "Interactive entry points (sshd)";
    sliceConfig = {
      CPUWeight = 1500;
      IOWeight = 1000;
      MemoryMin = "256M";
    };
  };
  systemd.services.sshd = {
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Slice = "interactive.slice";
      OOMScoreAdjust = -900;
      MemoryMin = "128M";
    };
  };

  systemd.slices.background = {
    description = "Background loads (low CPU/IO weight)";
    sliceConfig = {
      CPUWeight = 20;
      IOWeight = 20;
      # Hardware reservation for interactive: the threads of physical
      # cores 6 and 7 (cpu12 to cpu15) are reserved for hermes.slice. A build,
      # even at 12 threads, cannot touch them: it is a floor, not
      # a share. The weight above arbitrates the rest.
      AllowedCPUs = "0-11";
    };
  };

  # Android emulator (capture): the biggest single consumer measured
  # (124 % of a core), and it lived in system.slice at weight 100, on par
  # with the gateway. It drops to the background with a hard cap.
  systemd.services.android-emulator.serviceConfig = {
    Slice = "background.slice";
    CPUQuota = "400%";
  };

  # Local vision model (qwen3-vl:4b) + mem0 embeddings.
  systemd.services.ollama = {
    serviceConfig = {
      Slice = "background.slice";
      # Safe cap: 6 cores out of 16. The governor raises it to 12 when
      # nobody is waiting for CPU.
      CPUQuota = "600%";
      Nice = 10;
    };
    environment = {
      # 8 threads max (8c/16t): beyond that the model fights over L3.
      OLLAMA_NUM_THREADS = "8";
      OLLAMA_KEEP_ALIVE = "5m";
    };
  };

  # Any build launched by a nix client goes through the daemon.
  systemd.services.nix-daemon.serviceConfig.Slice = "background.slice";

  # winnie batches: ORPHANS since Winnie left the host config
  # (13/11/2026, cf services/default.nix and deploy/winnie/README.md). These
  # four `systemd.services.winnie-*` carried ONLY overrides
  # (Slice/CPUQuota), with no ExecStart: NixOS generated invalid system
  # units (`LoadError=BadUnitSetting`, invisible to `systemctl --failed`,
  # cf. nixos-service-troubleshooting), and winnie-ingest-nightly no longer ran
  # at all (its timer lived in the removed winnie module). Removed on
  # 17/11/2026 (night repair): winnie-ingest-nightly is redeployed as a
  # hermes USER unit (deploy/winnie/winnie-ingest-nightly.service,
  # same pattern as backend/frontend/dev). winnie-calories, winnie-gmaps-scrape
  # and winnie-hours-refresh remain to be reworked the same way the day they become
  # useful (not done here: no ready binary in deploy/winnie for them).
  systemd.slices.winnie-browser = {
    description = "winnie browser jobs (cap 30 % of total CPU) - UNUSED since 17/11/2026, winnie runs outside the host config";
    sliceConfig = {
      CPUQuota = "480%";
      CPUWeight = 20;
      IOWeight = 20;
    };
  };

  # Governor: widens the caps when marc's sessions are not
  # queuing for CPU, restores them as soon as they need it. The state lives
  # in /run (the script creates the directory): reboot = return to the declarative
  # caps.
  systemd.services.winnie-cpu-governor = {
    description = "CPU governor for winnie jobs (capped/wide depending on user.slice pressure)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${./governor.py}";
    };
  };

  systemd.timers.winnie-cpu-governor = {
    description = "Tick of the winnie CPU governor (15 s)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "90s";
      OnUnitActiveSec = "15s";
      AccuracySec = "3s";
      Unit = "winnie-cpu-governor.service";
    };
  };
}
