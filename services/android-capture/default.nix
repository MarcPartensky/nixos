# services/android-capture/default.nix
# Network capture of emulated Androids on tower, isolated per target.
#
# WHY at the network level and not via a proxy: a proxy only sees what
# agrees to go through it. QUIC, Google Play Services and the SDKs that talk
# directly escape it. Interface-level capture sees everything, in-
# cluding the encrypted part, but without the content (TLS): it is metadata, not
# plaintext. For plaintext you need a proxy with a trusted certificate, which
# is another topic.
#
# HOW AN APP IS ISOLATED: one target = one Android instance, hence one
# interface and its own pcaps. It is the only clean isolation, and it
# requires no root: instance A cannot appear in the files of
# instance B. Putting one app per instance (an AVD for the work app,
# the Waydroid container for another) thus gives one pcap per app.
#
# What does NOT work to isolate without root on the same instance: separating the
# pcaps per app. The apps of a container share a single network namespace,
# everything arrives mixed on the bridge. Android can attach each socket to a
# uid (`dumpsys netstats` for per-packet volumes, `/proc/net/tcp` for the uid
# of each live connection), which lets you attribute the flows of a pcap to the
# apps by joining on the ports, but that is a reconstruction, not a
# separate capture. A per-uid capture requires marking in iptables with
# `-m owner --uid-owner <uid> -j NFLOG --nflog-group N` then capturing on
# `nflog:N`, hence root in the instance.
#
# WHY not root on the host side: a tcpdump only needs CAP_NET_RAW (and
# CAP_NET_ADMIN for promiscuous-mode capture on a bridge). We give these
# two capabilities to the process via AmbientCapabilities, which is narrower than
# running the capture as root. Corollary: NoNewPrivileges must stay
# false, systemd refuses the combination AmbientCapabilities + NoNewPrivileges.
# The user is static (not DynamicUser) because several units
# share the same state tree: with transient uids, each startup
# would reattribute the directories.
#
# TARGETS FED BY AN EMULATOR: an AVD goes out through the host network stack,
# so it has no interface to capture. We declare an empty interface
# list for it: the module creates the directory and the digest, and it is the `-tcpdump` of
# the emulator that writes into it, for example
#   NIX_ANDROID_EMULATOR_FLAGS="... -tcpdump /var/lib/android-capture/pcap/avd/emu.pcap"
# The target directories are in 0770 so that the user who launches the emulator
# (hermes) can write there, while the pcaps stay with the group.
#
# READING THE RESULT:
#   ls /var/lib/android-capture/pcap/<target>/            # 10-min files, 12 h of history
#   cat /var/lib/android-capture/digest/<target>.txt      # hosts of the latest file
#   cat /var/lib/android-capture/digest/<target>-all.txt  # hosts seen, cumulative
#   tshark -r <file>.pcap -Y 'tls.handshake.extensions_server_name' \
#       -T fields -e tls.handshake.extensions_server_name | sort -u
#
# DEPENDENCY: the waydroid0 interface only exists if waydroid-container runs.
# BindsTo ties the lifecycle, so as not to let tcpdump fail in a loop when
# Android is stopped.
{ pkgs, lib, ... }:
let
  # One target per Android instance. The interface list is that of the host:
  # empty = fed by an emulator's -tcpdump.
  captures = {
    waydroid = [ "waydroid0" ];
    avd = [ ];
  };

  # Rotation: one file every 10 minutes, 72 kept, i.e. 12 h.
  rotateSeconds = 600;
  rotateKeep = 72;

  user = "android-capture";
  stateDir = "/var/lib/android-capture";

  # tcpdump writes timestamped files and overwrites the oldest when the
  # -W limit is reached.
  captureScript = target: ifaces: pkgs.writeShellScript "android-capture-${target}" ''
    set -eu
    exec ${pkgs.tcpdump}/bin/tcpdump \
      ${lib.concatMapStringsSep " " (i: "-i ${i}") ifaces} \
      -s 0 -w "${stateDir}/pcap/${target}/%Y%m%d-%H%M%S.pcap" \
      -G ${toString rotateSeconds} -W ${toString rotateKeep}
  '';

  # Digest per target: summary of the last file written under a stable name, plus
  # a cumulative list of hosts already seen. Used to answer "this app talks to
  # whom" without opening wireshark, and to spot an SDK that reappears. The raw
  # file is deduplicated on each pass, so it does not grow endlessly.
  digestScript = target: pkgs.writeShellScript "android-capture-digest-${target}" ''
    set -eu
    dir="${stateDir}/pcap/${target}"
    out="${stateDir}/digest"
    latest=$(ls -1t "$dir"/*.pcap 2>/dev/null | head -1 || true)
    [ -n "$latest" ] || { echo "${target}: no pcap yet"; exit 0; }

    ${pkgs.tshark}/bin/tshark -r "$latest" \
      -Y 'dns.flags.response==0 or tls.handshake.extensions_server_name' \
      -T fields -e dns.qry.name -e tls.handshake.extensions_server_name 2>/dev/null \
      | tr '\t' '\n' | grep -v '^$' | sort -u > "$out/${target}.txt.new"
    mv "$out/${target}.txt.new" "$out/${target}.txt"

    cat "$out/${target}.txt" >> "$out/${target}-all.raw"
    sort -u "$out/${target}-all.raw" > "$out/${target}-all.txt"
    sort -u "$out/${target}-all.raw" > "$out/${target}-all.raw.new"
    mv "$out/${target}-all.raw.new" "$out/${target}-all.raw"
    echo "${target}: $latest"
  '';

  # ---- AVD emulator as a service -------------------------------------------
  # The androidenv runner creates the AVD in a temporary directory, boots, then exits
  # leaving qemu running. Launched as-is as ExecStart, systemd would see the
  # service as "finished" while the emulator is still running: we wrap it to
  # stay alive as long as qemu holds the capture, which gives a service that
  # systemd really follows and that a `systemctl stop` stops, emulator included.
  #
  # The runner path is pinned on purpose: it comes from a separate flake
  # (the hinge-re project, which builds the Play Store image). If this flake changes
  # image or options, this path changes and it must be updated here as
  # in its justfile.
  emulatorRunner = "/nix/store/kyfmkz5jayxkz1gg6s1p9lsgdgjf6mf2-hinge-test/bin/run-test-emulator";

  emulatorScript = pkgs.writeShellScript "android-emulator" ''
    set -eu
    export HOME=${stateDir}
    # avdmanager (which creates the AVD) is Java and requires JAVA_HOME: the runner
    # calls the NON-wrapped version of the Android SDK, the one that does not embed
    # the JDK. We reuse the JDK that androidenv itself uses in its
    # wrapper (openjdk 17), a more recent JDK makes these cmdline-tools fail.
    export JAVA_HOME=${pkgs.jdk17}
    export PATH=${pkgs.jdk17}/bin:${pkgs.procps}/bin:${pkgs.coreutils}/bin:$PATH
    export NIX_ANDROID_EMULATOR_FLAGS="-no-window -no-audio -gpu swiftshader_indirect -no-snapshot -memory 3072 -no-metrics -tcpdump ${stateDir}/pcap/avd/emu.pcap"
    # The APK directory is created by the service itself: it is the one that
    # consumes it, and a tmpfiles rule does not guarantee its presence at the first
    # startup following the addition of the rule.
    install -d -m 0770 ${stateDir}/apks
    ${emulatorRunner} &
    runner=$!

    # We wait for the capture to appear, time-bounded, and we
    # fail if the emulator does not start rather than staying alive for nothing.
    demarre=0
    for _ in $(seq 1 90); do
      if pgrep -f "tcpdump ${stateDir}/pcap/avd/emu.pcap" >/dev/null 2>&1; then
        demarre=1
        break
      fi
      # Runner exited without launching qemu: no point waiting for the timeout to end.
      kill -0 "$runner" 2>/dev/null || break
      sleep 2
    done
    if [ "$demarre" != 1 ]; then
      echo "the emulator did not start" >&2
      exit 1
    fi

    # Stays alive as long as this target's capture is open: no other
    # process on the machine carries this file path.
    while pgrep -f "tcpdump ${stateDir}/pcap/avd/emu.pcap" >/dev/null 2>&1; do
      sleep 10
    done
  '';

  # Installs the work APKs as soon as the device has finished booting. The AVD being
  # recreated on each startup, the installation is part of the lifecycle of the
  # service: we drop a file in apks/ (directory writable by the
  # group) and it is picked up at the next boot.
  installApkScript = pkgs.writeShellScript "android-avd-install" ''
    set -u
    adb=${pkgs.android-tools}/bin/adb
    for _ in $(seq 1 60); do
      $adb wait-for-device >/dev/null 2>&1 && break
      sleep 5
    done
    for _ in $(seq 1 60); do
      [ "$($adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
      sleep 5
    done
    for apk in ${stateDir}/apks/*.apk; do
      [ -f "$apk" ] || continue
      echo "installing $apk"
      $adb install -r "$apk" || echo "failed to install $apk"
    done
  '';

  hardening = {
    User = user;
    Group = user;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    ReadWritePaths = [ stateDir ];
  };
in
{
  users.users.${user} = {
    isSystemUser = true;
    group = user;
    home = stateDir;
    description = "Android network capture";
  };
  users.groups.${user} = { };

  # marc must be able to read the captures without root, and hermes too to launch
  # the emulators that write into them. The directories stay in 0770: read and
  # write for the group, nothing for others. Belonging to a group only
  # takes effect at the next login (or `newgrp`).
  users.users.marc.extraGroups = [ user ];
  users.users.hermes.extraGroups = [ user ];

  systemd.tmpfiles.rules =
    [
      "d ${stateDir} 0750 ${user} ${user} -"
      "d ${stateDir}/digest 0770 ${user} ${user} -"
      "d ${stateDir}/apks 0770 ${user} ${user} -"
    ]
    ++ lib.mapAttrsToList
      (target: _: "d ${stateDir}/pcap/${target} 0770 ${user} ${user} -")
      captures;

  # A single assignment to systemd.services: declaring two in the same
  # attribute (services.android-emulator then services = ...) is an evaluation
  # error, so everything is merged here.
  systemd.services =
    {
      # The emulator itself, as a service: without it the avd target lives only as long
      # as an interactive session is willing to launch it. The AVD is recreated on each
      # startup (the androidenv runner works in a temporary directory),
      # hence the installation of the APKs dropped in apks/ just after boot.
      android-emulator = {
        description = "Android emulator (AVD) feeding the avd capture target";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        # The runner comes from a SEPARATE flake (hinge-re) and its path in the
        # store is pinned above: when this flake is no longer in the GC
        # roots, the path disappears and the unit looped every 20 s
        # (observed 17/11/2026: 342 restarts, ~1,4 s of CPU per round, without
        # ever launching qemu). ConditionPathExists makes the unit SKIP
        # cleanly instead of making it fail in a loop; it suffices to
        # rebuild the flake for the service to restart at the next boot.
        unitConfig.ConditionPathExists = emulatorRunner;
        # PATH is not inherited from an interactive session: without an explicit jdk,
        # avdmanager (Java) exits with "JAVA_HOME is not set" and the AVD is never
        # created. Without procps or coreutils, the `seq` and `pgrep` of the script are
        # not found and the unit thinks it is finished immediately.
        path = with pkgs; [ jdk procps coreutils android-tools ];
        serviceConfig = hardening // {
          # Type simple: the unit is considered started as soon as it forks, so a
          # switch never waits for the AVD to boot. The script stays alive so
          # that systemd follows the emulator, and fails time-bounded if
          # the emulator does not start.
          ExecStart = "${emulatorScript}";
          Restart = "on-failure";
          RestartSec = "20s";
          # qemu needs time to hand back control cleanly.
          TimeoutStopSec = "60s";
          # /dev/kvm is in 0666 on this machine: no kvm group to join.
        };
      };

      # The installation of the work APKs waits for a fresh AVD to boot, so
      # several minutes: a separate unit so that the emulator starts right
      # away and the system does not wait for an Android boot.
      android-avd-install = {
        description = "Installation of the work APKs into the AVD";
        # Without an emulator there is no device to serve: this oneshot
        # waited for adb 5 min then got killed by TimeoutStartSec=900
        # (observed 16/11/2026). Same condition as android-emulator.
        unitConfig.ConditionPathExists = emulatorRunner;
        # No wantedBy: a oneshot pulled by multi-user.target holds back all
        # activation, hence system startup, during the Android boot.
        # It is a timer that triggers it, and a timer holds nothing back.
        after = [ "android-emulator.service" ];
        path = with pkgs; [ android-tools coreutils ];
        serviceConfig = hardening // {
          Type = "oneshot";
          ExecStart = "${installApkScript}";
          # A fresh AVD can take ten minutes to boot on a loaded host.
          TimeoutStartSec = "900";
        };
      };
    }
    //
    lib.mapAttrs'
      (target: ifaces:
        lib.nameValuePair "android-capture-${target}" {
          description = "Android network capture (${target})";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ]
            ++ lib.optional (builtins.elem "waydroid0" ifaces) "waydroid-container.service";
          bindsTo = lib.optional (builtins.elem "waydroid0" ifaces) "waydroid-container.service";
          serviceConfig = hardening // {
            ExecStart = "${captureScript target ifaces}";
            Restart = "on-failure";
            RestartSec = "10s";
            AmbientCapabilities = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
            CapabilityBoundingSet = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
            # Required for the ambient capabilities to take effect.
            NoNewPrivileges = false;
          };
        })
      (lib.filterAttrs (_: ifaces: ifaces != [ ]) captures)
    // lib.mapAttrs'
      (target: _:
        lib.nameValuePair "android-capture-digest-${target}" {
          description = "Digest of contacted hosts (${target})";
          serviceConfig = hardening // {
            Type = "oneshot";
            ExecStart = "${digestScript target}";
          };
        })
      captures;

  systemd.timers =
    {
      android-avd-install = {
        description = "Installation of the work APKs in the AVD after boot";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          Unit = "android-avd-install.service";
        };
      };
    }
    // lib.mapAttrs'
    (target: _:
      lib.nameValuePair "android-capture-digest-${target}" {
        description = "Periodic digest of the Android capture (${target})";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "10min";
          Unit = "android-capture-digest-${target}.service";
        };
      })
    captures;
}
