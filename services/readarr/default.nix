{
  lib,
  pkgs,
  ...
}:
# Readarr = books. Its data directory is under /home (like Sonarr) and its
# module does not mask /home, so it works as-is (verified: service
# active, port 8088 responds 200). Only the library changes: /srv/media/books
# (`media` group, cf. services/media), to be selected in the UI.
{
  services.readarr = {
    enable = true;
    user = "marc";
    group = "users";
    dataDir = "/home/marc/readarr";
    settings = {
      # update.mechanism = "internal";
      server = {
        # No urlbase (see services/radarr): a non-empty base makes
        # any path outside the base redirect with 307, /api/v3/... included.
        port = 8088;
        bindaddress = "*";
      };
    };
  };

  # Shared media: imported files must remain writable by the
  # other members of the `media` group.
  systemd.services.readarr.serviceConfig.UMask = lib.mkForce "0002";
}
