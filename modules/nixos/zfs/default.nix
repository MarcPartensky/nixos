{ pkgs, ... }:
{
  boot.zfs.forceImportRoot = false; # nouveau défaut 26.11, réduit le risque de double-import silencieux

  # Retention : le pool est a ~96 % (1 To, slop ZFS ~32 Go deja mange), et les
  # snapshots retiennent les blocs supprimes (nix store GC, builds) : ~57 Go sur
  # nixos/nix et ~49 Go sur nixos/root au 12/11/2026. Les snapshots `frequent`
  # ne s'accumulent pas (6 max, rotation horaire), donc le levier est la
  # profondeur des etages longs : monthly 12 -> 3 et weekly 4 -> 2 liberent les
  # mois anciens (jusqu'a 18 Go chacun sur nixos/root). Note : zfs-auto-snapshot
  # n'elague qu'a SON passage (monthly = 1x/mois), donc reduire ici ne libere
  # rien immediatement ; detruire a la main les snapshots en trop (zfs destroy).
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
