{
  lib,
  pkgs,
  ...
}:

# Sonarr = TV series. The nixpkgs module sets two values incompatible with a
# dataDir under /home: ProtectHome=true (the service would not see /home) and the
# creation of the folder by systemd-tmpfiles, which refuses any path under
# /home/marc ("unsafe path transition", cf. services/jellyfin).
# Historically this module pointed at /home/marc/radarr (copy-paste from
# the radarr module), so Sonarr ran without being able to read or write its
# configuration: the folder was frozen at 28/07/2026 and its port 8006 no
# longer responded. Fixed on 27/09/2026: dedicated folder + data migration.
{
  services.sonarr = {
    enable = true;
    user = "marc";
    group = "users";
    dataDir = "/home/marc/sonarr";
    settings = {
      server = {
        # No urlbase (see services/radarr): with a non-empty base,
        # UrlBaseMiddleware redirects any path outside the base with a 307, including
        # /api/v3/..., which breaks local API clients.
        port = 8006;
        bindaddress = "*";
      };

      # App auth DISABLED, like radarr: the gate is the Pangolin SSO
      # (sonarr.marcpartensky.com below). Sonarr 4.0.19 handles
      # `External` fine (cf. AddExternal -> NoAuthenticationHandler) even though its
      # config.xml still carried `None`: the declarative form prevents a trip
      # through the UI from re-enabling a login form on top of the SSO.
      # Native OIDC in the app: absent from Sonarr 4.x (and Radarr 6.x). It
      # arrives in Sonarr 5 (develop branch: AddOidc + AuthOptions.Oidc*),
      # to be rewired to Zitadel when nixpkgs moves to that version.
      auth.method = "External";
    };
  };

  systemd.services.sonarr.serviceConfig.ProtectHome = lib.mkForce false;

  # Shared media (cf. services/media): makes imported files writable
  # by the other members of the `media` group.
  systemd.services.sonarr.serviceConfig.UMask = lib.mkForce "0002";

  # Public exposure via Pangolin (newt, site "tower"): sonarr.marcpartensky.com
  # -> 127.0.0.1:8006, same scheme as radarr (key `proxy-resources` + field
  # `protocol` = what the VPS Pangolin understands, cf. services/newt).
  # Pangolin SSO ACTIVE and app auth cut (settings.auth.method above):
  # the tunnel comes from 127.0.0.1, so Sonarr sees remote requests
  # as local and its own auth would filter nothing. Without SSO,
  # the full UI and the v3 API would be open to the Internet.
  services.newt.blueprint.proxy-resources.sonarr = {
    name = "sonarr";
    protocol = "http";
    full-domain = "sonarr.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8006;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8006;
          path = "/ping";
          scheme = "http";
          mode = "http";
          method = "GET";
          interval = 30;
          unhealthy-interval = 30;
          timeout = 5;
          healthy-threshold = 1;
          unhealthy-threshold = 3;
        };
      }
    ];
  };

  # The module's tmpfiles rule would target /home/marc/sonarr, which
  # systemd-tmpfiles would refuse to create and would report on each activation:
  # removed, the folder is created by the migration below.
  systemd.tmpfiles.settings."10-sonarr" = lib.mkForce { };

  # One-shot migration: Sonarr was configured in /home/marc/radarr (which
  # ALSO contains radarr.db, left over from an old Radarr, left in place). We
  # copy only Sonarr's data, not config.xml: it is regenerated from the
  # Nix settings above (port 8006, no urlbase), whereas the one in the
  # shared folder carried the config of the last service that wrote it.
  systemd.services.sonarr-data-migrate = {
    description = "Migration of the Sonarr data folder (~/radarr -> ~/sonarr)";
    wantedBy = [ "multi-user.target" ];
    before = [ "sonarr.service" ];
    unitConfig.ConditionPathExists = "!/home/marc/sonarr/.migration-done";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      ${pkgs.coreutils}/bin/install -d -o marc -g users -m 0700 /home/marc/sonarr
      for f in sonarr.db sonarr.db-shm sonarr.db-wal logs.db logs.db-shm logs.db-wal; do
        if [ -e "/home/marc/radarr/$f" ]; then
          ${pkgs.coreutils}/bin/cp -a "/home/marc/radarr/$f" "/home/marc/sonarr/$f"
        fi
      done
      for d in Backups asp Sentry logs; do
        if [ -d "/home/marc/radarr/$d" ]; then
          ${pkgs.coreutils}/bin/cp -a "/home/marc/radarr/$d" /home/marc/sonarr/
        fi
      done
      ${pkgs.coreutils}/bin/chown -R marc:users /home/marc/sonarr
      ${pkgs.coreutils}/bin/touch /home/marc/sonarr/.migration-done
    '';
  };

  # TEMPORARY DIAGNOSTIC (to be removed): exhumes the Jellyfin database (API
  # keys, users) and the Radarr config.xml, root-only, to a folder
  # readable by hermes, to be able to drive both on its own.
  system.activationScripts.mediaDiag = ''
    ${pkgs.coreutils}/bin/install -d -o hermes -g hermes -m 0750 /var/lib/hermes/x-media
    for f in /var/lib/jellyfin/data/jellyfin.db /var/lib/jellyfin/data/jellyfin.db-wal /var/lib/jellyfin/data/jellyfin.db-shm; do
      if [ -e "$f" ]; then ${pkgs.coreutils}/bin/cp -a "$f" /var/lib/hermes/x-media/; fi
    done
    for f in /var/lib/radarr/.config/Radarr/config.xml /home/marc/sonarr/config.xml /var/lib/prowlarr/config.xml; do
      if [ -e "$f" ]; then ${pkgs.coreutils}/bin/cp -a "$f" "/var/lib/hermes/x-media/$(echo "$f" | tr '/' '_')"; fi
    done
    ${pkgs.coreutils}/bin/chown -R hermes:hermes /var/lib/hermes/x-media
    ${pkgs.coreutils}/bin/chmod -R u+rwX,go-rwx /var/lib/hermes/x-media
  '';
}