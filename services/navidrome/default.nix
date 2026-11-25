{
  config,
  pkgs,
  lib,
  ...
}:

{
  services.navidrome = {
    enable = true;
    settings = {
      Address = "0.0.0.0";
      Port = 4533;
      # Shared media: /srv/media/music (group `media`, cf. services/media),
      # and no longer /home/marc/media/music which forced giving navidrome
      # traverse permission on marc's home (0700) and made it scan an
      # empty library.
      MusicFolder = "/srv/media/music";
      # DataFolder = "/var/lib/navidrome/data";
      LogLevel = "info";
      # NOT `ScanSchedule`: that flat key was the pre-0.5x name and 0.64 ignores it
      # with "Option 'ScanSchedule' is not recognized and will be ignored", so no
      # periodic scan was ever scheduled (only scan-on-startup ran). The 0.64 key
      # is the nested Scanner.Schedule, verified to log "Scheduling periodic scan".
      Scanner.Schedule = "@every 1h";
      TranscodingCacheSize = "500MB";
      DefaultLanguage = "fr";
      # Upstream SSO (Pangolin + Zitadel): the proxy injects Remote-User when the
      # Pangolin session is valid (badger). Navidrome has no native OIDC, it
      # only knows how to trust a header set by a trusted proxy.
      # Consequence to be aware of: TrustedSources = 127.0.0.1 trusts ANY
      # local process; and the header value must be EXACTLY the Navidrome
      # user_name (otherwise a second account is created on first login).
      # /rest/* and /share/* are outside the Pangolin gate (ACCEPT rules in
      # Pangolin), so Subsonic clients keep their Basic auth.
      ExtAuth.TrustedSources = "127.0.0.1/32";
      ExtAuth.UserHeader = "Remote-User";
    };
  };

  # Local patch of Navidrome (services/navidrome/drop-estimated-content-length.patch).
  # aonsoku (the web client, services/aonsoku.nix) always sends
  # `estimateContentLength=true` on /rest/stream, and every file of the library is
  # m4a, which aonsoku forces to transcode to opus. Navidrome then answers with an
  # ESTIMATED Content-Length (duration * bitRate / 8 * 1024) that never matches the
  # real opus output. Go's HTTP server refuses a body that disagrees with the
  # declared length: it aborts the response mid-stream ("Error sending transcoded
  # file: http: wrote more than the declared Content-Length"), the client receives
  # a truncated body and plays nothing ("unable to play the song, check the
  # server"). Playing the same track again worked, from the transcoding cache.
  # The patch makes Navidrome ignore the parameter and stream chunked, which is
  # what every client that does not ask for the estimate already gets. Upstream
  # fixes the same mismatch on master (DevMatchEstimatedContentLength: pad or cut
  # the body to match the declared length).
  services.navidrome.package = pkgs.navidrome.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./drop-estimated-content-length.patch ];
  });

  systemd.services.navidrome = {
    serviceConfig = {
      StateDirectory = "navidrome";
      DeviceAllow = "";
      LockPersonality = true;
      PrivateDevices = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      # The music is no longer in /home: no more need for BindPaths or to
      # traverse the home, the module hardening can stay active.
      ProtectHome = lib.mkForce true;
    };
  };

  # Public exposure via Pangolin (newt, site "tower"): navidrome.marcpartensky.com
  # -> 127.0.0.1:4533. `proxy-resources` schema + `protocol` = the one understood by
  # the VPS Pangolin (cf. services/newt, services/radarr).
  #
  # Pangolin SSO: Zitadel is Pangolin's global IdP, the web UI login goes
  # through Zitadel, and badger injects Remote-User which Navidrome reads via ExtAuth
  # (cf. settings above), so no second login in the app.
  # Subsonic clients (Feishin, mobile apps, subtracks) do not follow a
  # browser redirect: /rest/* and /share/* leave the gate via rules
  # `allow` DECLARED HERE (and not set by hand in Pangolin: each
  # blueprint application recreates the resource and erases its rules, which
  # puts /rest/* back behind the SSO and breaks all clients).
  services.newt.blueprint.proxy-resources.navidrome = {
    name = "navidrome";
    protocol = "http";
    full-domain = "navidrome.marcpartensky.com";
    auth.sso-enabled = true;
    rules = [
      {
        action = "allow";
        match = "path";
        value = "rest/*";
      }
      {
        action = "allow";
        match = "path";
        value = "share/*";
      }
    ];
    targets = [
      {
        hostname = "127.0.0.1";
        port = 4533;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 4533;
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

  # No openFirewall: tower is behind NAT, only the newt tunnel exposes
  # Navidrome, and the Pangolin SSO + its own auth filter access.
  # networking.firewall.allowedTCPPorts = [ 4533 ];
}
