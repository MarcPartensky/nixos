# services/octo/default.nix
# Octo (github.com/winters27/octo, GPL-3, Rust): OpenSubsonic proxy in front of
# Navidrome. It adds what Navidrome cannot do:
#   - search outside the library (Deezer + YouTube Music + Last.fm) and play
#     right away a missing track, as a YouTube preview via yt-dlp;
#   - a radio that learns from listens (Last.fm, YouTube Music, ListenBrainz),
#     served to Subsonic clients as stations / playlists;
#   - above all: download on a heart (or a "+") the missing track, tag it
#     and drop it into the library that Navidrome scans.
# Navidrome has no OIDC nor external audio source: a plugin (capabilities
# metadata/scrobbler/lyrics/sonicSimilarity) CANNOT make a missing
# file playable. It is this gap that this proxy fills.
#
# Two OCI containers (podman, virtualisation.oci-containers, same scheme as
# services/aonsoku):
#   - octo             : the app + its Subsonic API, published on 127.0.0.1:5274
#                        (octo.marcpartensky.com); it reaches Navidrome via
#                        host.containers.internal:4533, so the local service
#                        stays unreachable from the LAN;
#   - octo-yt-dlp-shim : yt-dlp + deno (JS runtime required by YouTube) behind
#                        /search and /stream, never published, reached by name on
#                        a dedicated podman network (podman's default network
#                        has no DNS).
#
# Deliberate choices:
#   - DownloadSource = YouTube: a heart downloads the YouTube M4A/MP3
#     directly. No slskd, so no Soulseek account nor port 50300
#     to open; switch to Soulseek/Lidarr later if marc wants FLAC.
#   - No octo-sonic (Sounds alike): it decodes the library continuously,
#     and tower already hosts marc's TTS stack on the CPU.
{
  config,
  lib,
  pkgs,
  ...
}: let
  dataDir = "/var/lib/octo";
  # Shared library (`media` group, setgid): downloaded files
  # inherit the media group and stay readable by navidrome/jellyfin.
  musicDir = "/srv/media/music";
  # Image tag: same version for both containers (the shim and the app
  # must stay aligned, cf. upstream docker-compose).
  tag = "2026.10.28";
in {
  # -- Dedicated podman network --------------------------------------------
  # NixOS has no option to declare a podman network: a oneshot creates it
  # (idempotent) and both container units start after it.
  systemd.services.podman-network-octo = {
    description = "Podman network `octo` (octo <-> yt-dlp-shim)";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    before = ["podman-octo.service" "podman-octo-yt-dlp-shim.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.podman}/bin/podman network exists octo ||
        ${pkgs.podman}/bin/podman network create octo
    '';
  };

  # -- Persistent state ----------------------------------------------------
  # Octo config (settings.json written by the dashboard, admin recovery
  # code) and yt-dlp caches (auto-updated binary, durations database).
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
    "d ${dataDir}/config 0700 root root -"
    "d ${dataDir}/ytdlp-bin 0755 root root -"
    "d ${dataDir}/ytdlp-cache 0755 root root -"
    "d ${dataDir}/ytshim 0755 root root -"
  ];

  # -- yt-dlp shim (search + stream resolution) ----------------------------
  virtualisation.oci-containers.containers.octo-yt-dlp-shim = {
    image = "ghcr.io/winters27/octo-yt-dlp-shim:${tag}";
    autoStart = true;
    extraOptions = [
      "--network=octo"
      "--umask=002"
    ];
    volumes = [
      # YouTube downloads must land where Navidrome scans.
      "${musicDir}:/music"
      # yt-dlp binary outside the image: its update survives the recreation
      # of the container (YouTube breaks an extractor every month).
      "${dataDir}/ytdlp-bin:/opt/ytdlp"
      "${dataDir}/ytdlp-cache:/root/.cache/yt-dlp"
      "${dataDir}/ytshim:/var/lib/ytshim"
    ];
    environment = {
      SHIM_THREADS = "32";
      MAX_CONCURRENT_YTDLP = "3";
      DOWNLOAD_ROOT = "/music";
      YTDLP_PATH = "/opt/ytdlp/yt-dlp";
      META_DB_PATH = "/var/lib/ytshim/meta.db";
      # visionos: stream URLs playable right away (the default yt-dlp
      # clients only give a valid URL after 4 to 14 s).
      YTDLP_PLAYER_CLIENT = "visionos";
    };
  };

  # -- Octo ----------------------------------------------------------------
  virtualisation.oci-containers.containers.octo = {
    image = "ghcr.io/winters27/octo:${tag}";
    autoStart = true;
    dependsOn = ["octo-yt-dlp-shim"];
    extraOptions = [
      "--network=octo"
      # host.containers.internal -> IP of the host seen from the podman bridge:
      # this is what makes it possible to reach Navidrome on 127.0.0.1:4533 without going
      # through the public domain (and therefore without depending on newt).
      "--add-host=host.containers.internal:host-gateway"
      "--publish=127.0.0.1:5274:8080"
      # setgid on the library + umask 002: root:media files in 664,
      # therefore readable by navidrome and by jellyfin.
      "--umask=002"
    ];
    volumes = [
      "${musicDir}:/music"
      "${dataDir}/config:/app/config"
    ];
    environment = {
      ASPNETCORE_ENVIRONMENT = "Production";
      TZ = "Europe/Paris";

      # --- Navidrome upstream ---
      Subsonic__Url = "http://host.containers.internal:4533";
      # Stream: nothing is cached on disk, the library is authoritative.
      Subsonic__StorageMode = "Stream";
      # A heart downloads a permanent copy: from YouTube here.
      Subsonic__DownloadSource = "YouTube";
      Subsonic__DownloadOnStar = "true";
      Subsonic__DownloadAlbumOnStar = "true";
      # Never re-download an already present track.
      Subsonic__SkipOwnedSongs = "true";
      # Artist/Album, like the existing library.
      Subsonic__FolderStructure = "Organized";
      # Search beyond the library (the core need).
      Subsonic__EnableSearchDiscovery = "true";
      Library__DownloadPath = "/music";

      # --- YouTube preview ---
      YouTube__ShimUrl = "http://octo-yt-dlp-shim:8080";

      # --- Radio: sources without an API key ---
      RadioSources__YouTubeMusic = "true";
      RadioSources__ListenBrainz = "true";
      # No octo-sonic: Sounds alike is disabled (see the header).
      RadioSources__SoundsAlike = "false";
      GeneratedPlaylists__PopularNow = "true";

      # --- Metadata ---
      Metadata__FetchLyrics = "true";
      # lrclib and lyricsovh only: kugou/netease are unofficial
      # APIs, out of the question to query them by default.
      Metadata__LyricsSources = "song,lrclib,lyricsovh";
      Metadata__ReplayGain = "true";

      Admin__SignIn = "required";
      Updates__Check = "true";
    };
  };

  # -- Public exposure -----------------------------------------------------
  # octo.marcpartensky.com -> 127.0.0.1:5274. The navidrome domain stays
  # pointed at Navidrome: no existing client moves, Octo is added.
  # /rest/* and /share/* exit the SSO gate, otherwise the Subsonic clients
  # (Feishin, Symfonium, mobile apps) cannot follow the Pangolin
  # redirect: same constraint as for navidrome.
  services.newt.blueprint.proxy-resources.octo = {
    name = "octo";
    protocol = "http";
    full-domain = "octo.marcpartensky.com";
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
        port = 5274;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 5274;
          # / returns a 302 to /app/ ; /health answers 200 directly.
          path = "/health";
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
}
