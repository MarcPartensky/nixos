{
  lib,
  ...
}:

# Radarr = the "Sonarr of movies". It downloads/renames and drops the movies
# into a library root, here /srv/media/movies: the SAME folder as
# Jellyfin's "Films" library. That's the useful connection: Jellyfin
# watches the folder in real time (watch enabled by default on a
# local storage), so an imported movie appears on its own. The "Connect"
# Emby/Jellyfin of Radarr (URL + Jellyfin API key) only serves to additionally
# trigger an explicit rescan on each import.
{
  services.radarr = {
    enable = true;
    user = "marc";
    group = "users";

    # PITFALL 1: do NOT reuse `dataDir = "/home/marc/radarr"` (value of the
    # sonarr module, which was copy-pasted here and there: Sonarr RAN with
    # -data=/home/marc/radarr). The two would share the same config folder.
    # PITFALL 2: a dataDir under /home/marc is impossible for Radarr: its
    # module sets ProtectHome=true and creates the folder via systemd-tmpfiles, which
    # REFUSES any path under /home/marc (cf. services/jellyfin, section
    # "unsafe path transition"). Hence this dataDir outside /home.
    dataDir = "/var/lib/radarr/.config/Radarr";

    settings = {
      server = {
        # NO urlbase: Radarr is served at the root of the domain. The example of the
        # nixpkgs module (urlbase = "localhost") was copied here for a while, and
        # with a non-empty value, UrlBaseMiddleware returns a 307 to
        # /<base><path> on EVERY out-of-base request: the local /login
        # redirected to /localhost/login, and an API client hitting
        # /api/v3/... received a 307 to /localhost/api/v3/... (a browser
        # follows, curl/arr-mcp does not).
        port = 8086;
        bindaddress = "*";
      };

      # App authentication DISABLED (method intended for a reverse
      # proxy that authenticates upstream). Radarr 6.x has NO OIDC support
      # (AuthenticationType = None/Basic/Forms/External only, cf. wiki
      # Servarr "OIDC NOT currently supported"), so behind Pangolin SSO
      # the only alternative was a second login in Radarr.
      # Accepted trade-off: everything that reaches 127.0.0.1:8086 from tower
      # (any local process) opens the UI without a password; the
      # API is still required on /api/v3 and the internet door remains Pangolin SSO
      # (the port is not open at the firewall).
      auth.method = "External";
    };
  };

  # Shared media (cf. services/media): UMask=0002 so that files
  # imported are modifiable by the other members of the `media` group
  # (the module sets 0022 by default, hence the mkForce).
  systemd.services.radarr.serviceConfig.UMask = lib.mkForce "0002";

  # Public exposure via Pangolin (newt, site "tower"): radarr.marcpartensky.com
  # -> 127.0.0.1:8086. `site` omitted: Pangolin assigns the site that applies the
  # blueprint. Key `proxy-resources` + field `protocol` = schema actually
  # understood by the VPS Pangolin (cf. detailed comment in services/newt).
  #
  # Pangolin SSO ACTIVE (unlike Jellyfin, which needs its native
  # clients): the newt tunnel hits locally, so Radarr sees remote
  # requests as local (127.0.0.1) and its own auth
  # "DisabledForLocalAddresses" would filter NOTHING. Without SSO, the full UI and
  # the v3 API (which is enough to drive Radarr) would be open to the Internet.
  services.newt.blueprint.proxy-resources.radarr = {
    name = "radarr";
    protocol = "http";
    full-domain = "radarr.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8086;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8086;
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

  # No more ProtectHome=false here: since the media is in /srv/media,
  # Radarr no longer touches marc's home at all (data in
  # /var/lib/radarr, downloads and library in /srv), so the
  # module hardening stays in place.

  # No openFirewall: like the other *arr, Radarr stays reachable
  # only from the machine (and via the tunnel/SSO if we expose it one day).
}