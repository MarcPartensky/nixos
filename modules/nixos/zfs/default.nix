{ pkgs, ... }:
{
  services.zfs.autoSnapshot = {
    enable = true;
    flags = "-k -p";
    frequent = 6; # Every 10 minutes (6 per hour)
    hourly = 24;
    daily = 7;
    weekly = 4;
    monthly = 12;
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
