# services/immich/default.nix
# Immich: the photos/videos interface (timeline, faces, search, map,
# mobile apps). Verdict of the SOTA comparison: it is the state of the art, 119k
# stars, release v3.4.1 upstream.
#
# PACKAGE: the one from pin 26.05 is immich 2.7.5, marked `insecure` by nixpkgs
# (two CVEs: CVE-2026-59258, CVE-2026-82272, and 2.x no longer receives
# fixes). So we take immich 3.2.2 from the flake's `unstable` input:
# the nixpkgs 26.05 module drives the package without issue (same environment
# variables, passthru `machine-learning` present).
#
# Decided architecture: the SOURCE OF TRUTH remains the ZFS tree
# /home/marc/media/photos (dataset `nixos/marc/media`), Garage is its backup
# mirror, and Immich only INDEXES it via an external library.
# No copy, no reupload: Immich has no S3 backend (feature request
# #30191 still open), so "Immich with Garage as backend" does not exist.
#
# The tree is exposed to the services by a READ-ONLY bind on /srv/photos:
#   - /home is protected (ProtectHome=true) in the systemd units, an explicit
#     bind on /srv bypasses that cleanly;
#   - ro mode guarantees that no app can write into the tree shared
#     with Syncthing and the Garage mirror (no sidecar, no thumbnail).
#
# Rights: the directories are 2770 marc:photos and the files hermes:photos,
# so the `immich` user is added to the `photos` group to read.
# PrivateUsers is disabled on immich-server only: under PrivateUsers,
# membership in a host group is not mapped and reading would fail.
#
# Resources: ML (faces, search) enabled, on CPU. tower has neither CUDA nor
# ROCm. The service runs in Slice system-immich.slice, so separable and
# measurable (systemd-cgtop -M system-immich.slice).
{ config, lib, pkgs, inputs, ... }:
let
  photosSource = "/home/marc/media/photos";
  photosMount = "/srv/photos";

  # Expensive indexing queues (cf. the "Indexing only at
  # night" section below for the reason and the schedule).
  immichHeavyQueues = [
    # `ocr` added on 14/11/2026: absent from this list, it ran 24/7
    # (848 jobs queued, 1 active non-stop) and it was IT that kept the
    # machine-learning service at ~190 % of a core in the middle of the day, while
    # all the other queues were properly paused. One queue forgotten here is enough
    # to void the schedule: check the /api/jobs list after each version
    # upgrade of immich, which can add some.
    "ocr"
    "thumbnailGeneration"
    "metadataExtraction"
    "videoConversion"
    "faceDetection"
    "facialRecognition"
    "smartSearch"
    "duplicateDetection"
  ];

  # Queue control via immich's HTTP API. The API key lives in a file
  # (created once by the admin in /var/lib/hermes/immich-jobs/api-key,
  # owned by hermes, readable by root). Without this file the units do
  # nothing and do not break the boot. Idempotence is carried by immich: a
  # queue already paused ignores a second "pause".
  immichJobsScript = pkgs.writeShellScript "immich-jobs-schedule" ''
    set -eu
    mode="''${1:-auto}"
    key_file=/var/lib/hermes/immich-jobs/api-key

    # Wait for the API to respond (the server takes ~20 s to start, and this script
    # can be launched right after it). 5 min max, then we give up cleanly.
    # 120 s were not enough: at the boot of 17/11/2026 the unit failed while
    # the machine had just restarted and two other services were looping.
    i=0
    while ! curl -sf -o /dev/null http://127.0.0.1:2283/api/server/ping; do
      i=$((i + 1))
      if [ "$i" -ge 150 ]; then
        echo "immich-jobs: API unreachable after 300 s, giving up" >&2
        exit 1
      fi
      sleep 2
    done

    if [ ! -r "$key_file" ]; then
      # Bootstrapping: without an API key, we create it with the admin account (password
      # left in a root-readable file). Otherwise the key would only exist by
      # creating it by hand, and the queues would stay active forever.
      pw_file=/var/lib/hermes/immich-jobs/admin-password
      if [ -r "$pw_file" ]; then
        pw=$(cat "$pw_file")
        tok=$(curl -s -X POST -H 'Content-Type: application/json' \
          -d "{\"email\":\"marc@marcpartensky.com\",\"password\":\"$pw\"}" \
          http://127.0.0.1:2283/api/auth/login | jq -r '.accessToken // empty')
        if [ -n "$tok" ]; then
          secret=$(curl -s -X POST -H "Authorization: Bearer $tok" \
            -H 'Content-Type: application/json' \
            -d '{"name":"hermes-indexation-nuit","permissions":["all"]}' \
            http://127.0.0.1:2283/api/api-keys | jq -r '.secret // empty')
          if [ -n "$secret" ]; then
            umask 077
            printf '%s' "$secret" > "$key_file"
            echo "immich-jobs: API key created in $key_file"
          fi
        fi
      fi
    fi

    if [ ! -r "$key_file" ]; then
      echo "immich-jobs: no API key ($key_file), nothing to do" >&2
      exit 0
    fi

    case "$mode" in
      auto)
        h=$(date +%-H)
        if [ "$h" -ge 4 ] && [ "$h" -lt 8 ]; then action=resume; else action=pause; fi
        echo "immich-jobs: auto mode at ''${h}h -> $action"
        ;;
      pause|resume) action="$mode" ;;
      *)
        echo "immich-jobs: unknown mode '$mode' (auto|pause|resume)" >&2
        exit 2
        ;;
    esac

    key=$(cat "$key_file")
    for q in ${lib.concatStringsSep " " immichHeavyQueues}; do
      code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
        -H "x-api-key: $key" -H 'Content-Type: application/json' \
        -d "{\"command\":\"$action\"}" \
        "http://127.0.0.1:2283/api/jobs/$q" || echo 000)
      echo "immich-jobs: $q -> $action ($code)"
    done
  '';
in
{
  fileSystems."${photosMount}" = {
    device = photosSource;
    fsType = "none";
    options = [
      "bind"
      "ro"
      "x-systemd.requires-mounts-for=${photosSource}"
    ];
  };

  # The `immich` user is created by the nixpkgs module only when the
  # service is active: we make the group addition conditional, otherwise the eval
  # breaks as soon as services.immich.enable = false.
  users.users.immich = lib.mkIf config.services.immich.enable {
    extraGroups = [ "photos" ];
  };

  services.immich = {
    # Marc had turned the service off at 13h41 (the 13h29 switch had turned it back on and
    # it relaunched indexing in the middle of the day). Turned back on here because the
    # nightly schedule is now in place: `immich-jobs-boot` pauses the
    # expensive queues from startup outside the 01:00-08:00 window, so
    # the UI responds without spinning the CPU. Set back to false to cut it dead.
    enable = true;
    host = "127.0.0.1";
    port = 2283;
    package = inputs.unstable.legacyPackages.${pkgs.system}.immich;
    # Immich's own library (uploads from the mobile app, thumbnails,
    # transcoded videos). On the root pool (191 GB free) and not on the
    # media dataset, whose 150 G quota must stay for the photos.
    mediaLocation = "/var/lib/immich";
    database.enable = true;
    redis.enable = true;
    machine-learning.enable = true;
    environment = {
      TZ = "America/New_York";
      # NO IMMICH_TELEMETRY_INCLUDE: immich 3.x validates this variable against
      # a list of events and "none" is no longer part of it -> the server
      # refuses to start ("Invalid telemetry found: none", crash loop at the
      # first switch, 14/11/2026). Without the variable, telemetry is
      # simply disabled.
    };
  };

  # Immich reads a directory, it has no S3 endpoint: the external library
  # is declared in the UI (Administration > External Libraries) on /srv/photos.
  systemd.services.immich-server.serviceConfig = {
    PrivateUsers = lib.mkForce false;
    BindReadOnlyPaths = [ "${photosMount}:/srv/photos" ];

    # -- Closed network: immich is an island ----------------------------------
    # eBPF filter by cgroup (systemd 260): the server can only reach the
    # loopback (Pangolin, and the ML when it lived here) and the tailscale IP of the
    # laptop that hosts the GPU ML. Nothing else of tower is
    # reachable from it, even if a flaw opened an outbound socket. The unix
    # sockets (PostgreSQL /run/postgresql, redis /run/redis-immich) are not
    # filtered by these rules, so the database and the cache are not affected.
    # What goes out to the tailnet goes through the tun, tailscaled encapsulates outside the
    # cgroup: the filter does not need to know the real network path (DIRECT or
    # DERP relay).
    IPAddressDeny = "any";
    IPAddressAllow = [
      "127.0.0.1/32" # Pangolin (newt) and the local ML
      "::1/128"
      "100.100.100.100/32" # MagicDNS, to resolve the laptop name
      "100.64.0.4/32" # laptop: immich-machine-learning on GPU
    ];
  };

  # -- Indexing only at night -----------------------------------------
  # A first scan of the tree (23 600 files) launches thumbnails, metadata,
  # face detection and smart search: measurement of 14/11/2026, ~1,8 core
  # for more than 8 min and load average > 20 on tower, which made
  # the service be stopped by hand (twice). Marc therefore wants these queues to
  # only run between 04:00 and 08:00 (window moved to 04:00 on 14/11/2026, he
  # wanted indexing at 4 a.m.); the server itself stays reachable
  # (UI, timeline, uploads).
  #
  # Three triggers, because the schedule alone is not enough: immich
  # ALWAYS starts with its queues active, so a simple switch at 13h
  # relaunched indexing until 08:00 the next day (experienced). Hence the
  # `immich-jobs-boot` service, wantedBy multi-user.target: it applies the correct
  # state from startup (and at each switch that activates it), including by
  # moving the hour computation into the script (`auto`).

  systemd.services.immich-jobs-pause = {
    description = "Immich: pauses the indexing queues (daytime)";
    after = ["immich-server.service"];
    wants = ["immich-server.service"];
    # A systemd unit's PATH contains neither curl nor jq: without this line
    # the script loops on "API unreachable" while the server responds.
    path = [pkgs.curl pkgs.jq pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${immichJobsScript} pause";
    };
  };

  systemd.services.immich-jobs-resume = {
    description = "Immich: resumes the indexing queues (night)";
    after = ["immich-server.service"];
    wants = ["immich-server.service"];
    path = [pkgs.curl pkgs.jq pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${immichJobsScript} resume";
    };
  };

  # Correct state at startup: pause except between 04:00 and 08:00.
  systemd.services.immich-jobs-boot = {
    description = "Immich: applies the queue state depending on the hour (04-08 = active)";
    after = ["immich-server.service"];
    wants = ["immich-server.service"];
    wantedBy = ["multi-user.target"];
    path = [pkgs.curl pkgs.jq pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${immichJobsScript} auto";
    };
  };

  systemd.timers.immich-jobs-pause = {
    description = "Immich: indexing window 04:00 -> 08:00 (pause at 08:00)";
    wantedBy = ["timers.target"];
    # Persistent = true on the pause only: after a daytime boot, the
    # missed pause replays right away; the resume, however, waits for the next
    # night (otherwise a boot at 12:00 would relaunch indexing in the middle of
    # the day, which marc refuses).
    timerConfig = {
      OnCalendar = "*-*-* 08:00:00";
      Persistent = true;
    };
  };

  systemd.timers.immich-jobs-resume = {
    description = "Immich: resume of the queues at 04:00";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = false;
    };
  };

  # Forces the (re)start of the server at the next switch: without that, a unit
  # stopped by hand stays so, and this module would only set timers
  # with no service to drive.
  systemd.services.immich-server.restartTriggers = [
    (pkgs.writeText "immich-job-schedule" "night-only-v4-4h")
  ];
}
