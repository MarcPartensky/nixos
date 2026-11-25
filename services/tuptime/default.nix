# services/tuptime: LOCAL availability history of the machine.
#
# Each machine keeps its own log: boots, cumulative uptime, cumulative DOWNTIME
# (the gap between shutdown and the next boot), availability ratio, and
# detection of unclean shutdowns. An SQLite database in /var/lib/tuptime, a oneshot
# at boot and a timer every 5 min: the CPU cost is nil (a few
# milliseconds per tick).
#
# It is the layer a central monitor CANNOT provide: it survives a
# network outage and a VPS failure, and it gives figures per machine
# rather than an impression ("does tower go down often?").
#
# Reading: `tuptime` (summary), `tuptime -t 10` (last ten events).
{ ... }:
{
  services.tuptime = {
    enable = true;

    # The timer is what matters: without a regular point while the machine
    # runs, an unclean shutdown is counted as if it had run until the next
    # boot, and the downtime disappears from the total.
    timer.enable = true;
  };

  # PITFALL (observed on 17/11/2026, two boots in a row): at startup,
  # tuptime.service (boot oneshot) and tuptime-sync.service (5 min timer)
  # can start in the SAME second. SQLite then sets a lock, the
  # oneshot exits with "database is locked" / status=1, and since it is
  # RemainAfterExit without Restart, the boot event of that startup is
  # LOST (the downtime is counted wrong). `after=` is not enough:
  # tuptime.service must be FINISHED before the timer triggers the sync.
  systemd.services.tuptime.before = [ "tuptime-sync.service" ];
  systemd.services.tuptime-sync.after = [ "tuptime.service" ];
}
