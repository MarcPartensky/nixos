{ pkgs, ... }:
{
  boot.zfs.forceImportRoot = false; # new 26.11 default, reduces the risk of silent double-import

  # Retention: the pool is at ~96% (1 TB, ZFS slop ~32 GB already consumed), and the
  # snapshots hold the deleted blocks (nix store GC, builds): ~57 GB on
  # nixos/nix and ~49 GB on nixos/root as of 12/11/2026. The `frequent` snapshots
  # do not accumulate (6 max, hourly rotation), so the lever is the
  # depth of the long tiers: monthly 12 -> 3 and weekly 4 -> 2 free the
  # old months (up to 18 GB each on nixos/root). Note: zfs-auto-snapshot
  # only prunes on ITS pass (monthly = 1x/month), so reducing here frees
  # nothing immediately; destroy by hand the excess snapshots (zfs destroy).
  services.zfs.autoSnapshot = {
    enable = true;
    flags = "-k -p";
    frequent = 6; # Every 10 minutes (6 per hour)
    hourly = 24;
    daily = 7;
    weekly = 2;
    monthly = 3;
  };
  #   # --- Daily Timer ---
  # systemd.timers.zfs-replication = {
  #   wantedBy = [ "timers.target" ];
  #   timerConfig = {
  #     OnCalendar = "daily";
  #     Persistent = true;
  #     RandomizedDelaySec = "1h";
  #   };
  # };

}
