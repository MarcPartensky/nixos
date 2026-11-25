# atop: activity recorder PER PROCESS, replayable after the fact.
#
# Answers "what spiked the CPU at 13:42?" without having had an htop
# open at the right moment. atop samples /proc (CPU, memory, I/O, network per
# process) to a daily binary file replayable with `atop -r`, and
# `atop-peaks` (below, added to PATH) prints the ranking of peaks without
# going through the TUI.
#
# Why atop and not sar/netdata: `sar` samples every 10 min by
# default, too coarse for a burst of a few seconds; netdata is a
# permanent web daemon far heavier. atop is a single process, ~8% of a core
# at a 10 s step (scan of /proc for ~4500 tasks, measured on tower).
#
# atopacctd enables kernel accounting: a process born and dead BETWEEN two
# samples (build, MCP spawn, shell command) stays visible in
# the next sample with its CPU. This is what makes the
# subprocess peaks visible even at a coarse step.
#
# Measured disk cost: ~1.4 GB per day (sample of ~170 KB with `-a`).
# We keep 3 days; raise `generations` if a long investigation is coming.
{
  pkgs,
  ...
}:
let
  logInterval = 10; # seconds between two samples
  generations = 3; # daily files kept
in
{
  programs.atop = {
    enable = true;
    atopacctService.enable = true; # ephemeral processes counted
    atopRotateTimer.enable = true; # one file per day
  };

  # The nixpkgs unit runs `atop -w .../atop_$(date +%Y%m%d) $LOGINTERVAL` with
  # LOGINTERVAL=600 by default. A NixOS drop-in overrides these variables
  # (last assignment wins in systemd).
  systemd.services.atop = {
    environment = {
      LOGINTERVAL = toString logInterval;
      LOGGENERATIONS = toString generations;
      LOGOPTS = "-a"; # CPU + memory + disk + network per process
    };
    # Background telemetry: yields to interactive work under contention.
    serviceConfig = {
      Slice = "background.slice";
      CPUWeight = 20;
      IOWeight = 20;
      Nice = 10;
    };
  };

  # No netatop (out-of-tree kernel module, kernel taint): the per-process
  # CPU and memory are enough for the peaks that concern us.

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "atop-peaks" ''
      exec ${pkgs.python3}/bin/python3 ${./atop-peaks.py} \
        --atop ${pkgs.atop}/bin/atop "$@"
    '')

    # Live view opened on the CPU ranking, top-style: -C sorts by CPU (already
    # the default), -1 shows the AVERAGE PER SECOND consumption instead of the
    # cumulative since the process start (without -1 an old inert process
    # stays forever first in the ranking), -c adds the full
    # command line (it is what identifies the culprit), 2 = one frame
    # every 2 s. In the TUI then: c CPU, m memory, d disk,
    # n network, t/T to move back in time, q to quit.
    # Colors: atop has NO theme system (no option, no
    # config file, the pairs are hardcoded in the binary and use
    # only the 8 basic ANSI colors, so it inherits the Catppuccin
    # Mocha palette of kitty but cannot take the lavender accent). -x only
    # disables red under heavy load.
    (pkgs.writeShellScriptBin "atopcpu" ''
      exec ${pkgs.atop}/bin/atop -C -1 -c 2 "$@"
    '')
  ];
}
