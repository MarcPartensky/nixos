{ config, lib, pkgs, inputs, ... }:

# SSH access from hermes to the phone (tmate model: the phone dials out to the VPS
# `rack`, no open port, no third party, no extra VPN app).
#
#   - local sshd (port 8023, hermes@tower key authorized, sftp);
#   - `phone-tunnel-loop`: loop `ssh -R 127.0.0.1:2224:127.0.0.1:8023 root@marcpartensky.com`;
#   - `phone-up`: idempotent startup (sshd + tunnel + watchdog + bounded wake-lock),
#     hooked to each session (.zprofile/.zshrc/.profile/.bashrc) AND to each
#     zsh prompt (precmd rate-limited 60s: any key in the app repairs it);
#   - `phone-watchdog`: replays `phone-up` every 2 min (safety net);
#   - `phone-update`: updates the conf (switch nix-on-droid, tarball-ttl 0);
#   - `phone-status`: diagnostic (verdicts + pids + logs);
#   - `nod-bootstrap`: (re)provisions the device (declarative switch + phone-up
#     + verification). Same script as the public artifact of the short link
#     (https://x.gd/a6gpx), installed here to be re-runnable without network.
#
# IMPORTANT (Xiaomi/HyperOS reliability): grant the Nix app the permission
# "Display pop-up windows in the background" (display over other apps),
# otherwise the wake-lock fails and MIUI kills the background processes.
#
# The tunnel's private key lives only on the phone (~/.ssh/relay_ed25519), never here.
# On the rack side, the restricted entry:
#   command="false",restrict,port-forwarding,permitlisten="127.0.0.1:2224" ssh-ed25519 AAAA... phone-relay

let
  inherit (config.user) home;

  # Ports specific to the device. `nixOnDroidConfigurations.default` is shared
  # by several devices (phone, tablet): if they used the same
  # numbers, their tunnels would fight over the same ports on the VPS's
  # loopback (`remote port forwarding failed for listen port 2224`).
  # Each flake instance therefore overrides `nod-access.*` (see flake.nix).
  inherit (config.nod-access) wsSocksPort wsHttpPort wsSshdPort;

  # The nixpkgs of nix-on-droid (inputs.nix-on-droid.inputs.nixpkgs) is old:
  # `pkgs.wstunnel` there is 0.5.1.0, a version that has neither `client` nor `-R`.
  # We therefore take the one from unstable, as for any package missing from the
  # nixpkgs pinned by the profile.
  wsTunnelPkg = inputs.unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.wstunnel;

  sshdDir = "${home}/sshd";
  sshdPort = 8023;

  relayHost = "marcpartensky.com";
  inherit (config.nod-access) relayPort;
  relayKey = "${home}/.ssh/relay_ed25519";

  # Keys authorized on the phone's sshd.
  authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKF3huPUXHP6P6SBXHHw9k7HGh6Cs8ntoRk2pnqrG2Hc hermes@tower"
  ];

  sshdConfig = pkgs.writeText "phone-sshd_config" ''
    Port ${toString sshdPort}
    ListenAddress 0.0.0.0
    HostKey ${sshdDir}/ssh_host_ed25519_key
    PidFile ${sshdDir}/sshd.pid
    AuthorizedKeysFile ${home}/.ssh/authorized_keys
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    UsePAM no
    AllowUsers ${config.user.userName}
    StrictModes no
    PrintMotd no
    Subsystem sftp internal-sftp
  '';

  authorizedKeysFile = pkgs.writeText "phone-authorized_keys"
    (lib.concatStringsSep "\n" authorizedKeys + "\n");

  tunnelLoop = pkgs.writeScriptBin "phone-tunnel-loop" ''
    #!${pkgs.runtimeShell}
    while true; do
      # Rotation: without this the log grows endlessly when the forward is refused
      # in a loop (measurement: 275 MB of wstunnel.log on the phone).
      log=${sshdDir}/tunnel.log
      if [ -f "$log" ] && [ "$(${pkgs.coreutils}/bin/stat -c %s "$log" 2>/dev/null || echo 0)" -gt 5000000 ]; then
        ${pkgs.coreutils}/bin/tail -c 200000 "$log" > "$log.tmp" && ${pkgs.coreutils}/bin/mv "$log.tmp" "$log"
      fi
      ${pkgs.openssh}/bin/ssh -NT \
        -i ${relayKey} \
        -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 \
        -o ServerAliveInterval=25 -o ServerAliveCountMax=4 \
        -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=${home}/.ssh/known_hosts \
        -R 127.0.0.1:${toString relayPort}:127.0.0.1:${toString sshdPort} \
        root@${relayHost}
      ${pkgs.coreutils}/bin/sleep 15
    done
  '';

  # WebSocket tunnel (wstunnel): publishes the phone's sshd on the VPS
  # (127.0.0.1:2225) plus two proxies on its loopback, a SOCKS5 (1081) and
  # an HTTP proxy (1082). Requests that go through there exit with the
  # phone's IP, not tower's, and all of it goes through ordinary wss, so
  # it survives a network that only lets out 443. The listening ports
  # live on the VPS's loopback (services/wstunnel) then are relayed
  # by the tower client.
  wsLoop = pkgs.writeScriptBin "phone-wstunnel-loop" ''
    #!${pkgs.runtimeShell}
    while true; do
      log=${sshdDir}/wstunnel.log
      if [ -f "$log" ] && [ "$(${pkgs.coreutils}/bin/stat -c %s "$log" 2>/dev/null || echo 0)" -gt 5000000 ]; then
        ${pkgs.coreutils}/bin/tail -c 200000 "$log" > "$log.tmp" && ${pkgs.coreutils}/bin/mv "$log.tmp" "$log"
      fi
      ${wsTunnelPkg}/bin/wstunnel client \
        -R tcp://127.0.0.1:${toString wsSshdPort}:127.0.0.1:${toString sshdPort} \
        -R socks5://127.0.0.1:${toString wsSocksPort} \
        -R http://127.0.0.1:${toString wsHttpPort} \
        wss://ws.marcpartensky.com
      ${pkgs.coreutils}/bin/sleep 15
    done
  '';

  phoneUp = pkgs.writeScriptBin "phone-up" ''
    #!${pkgs.runtimeShell}
    core=${pkgs.coreutils}/bin
    flock=${lib.getBin pkgs.util-linux}/bin/flock
    $core/mkdir -p ${sshdDir}
    lock=${sshdDir}/up.lock
    running=${sshdDir}/up.running
    exec 9>>"$lock" || exit 0
    if [ -x "$flock" ]; then
      if ! "$flock" -n 9; then
        # Lock already taken: if the holder (up.running, otherwise the lock's mtime)
        # has not advanced for 15 min, it is stuck -> we bypass it by
        # recreating the lock on a fresh inode (the stuck one keeps the old one).
        rts=$($core/stat -c %Y "$running" 2>/dev/null || echo 0)
        [ "$rts" -eq 0 ] && rts=$($core/stat -c %Y "$lock" 2>/dev/null || echo 0)
        now=$($core/date +%s)
        if [ "$rts" -gt 0 ] && [ "$((now - rts))" -gt 900 ]; then
          $core/rm -f "$lock"
          exec 9>>"$lock" || exit 0
          "$flock" -n 9 || exit 0
        else
          exit 0
        fi
      fi
    fi
    $core/touch "$running"
    trap '$core/rm -f "$running"' EXIT

    alive() {
      [ -f "$1" ] && kill -0 "$($core/cat "$1" 2>/dev/null)" 2>/dev/null
    }

    # 1) sshd (retries: startup can fail on a port still occupied)
    if alive ${sshdDir}/sshd.pid; then
      :
    else
      $core/rm -f ${sshdDir}/sshd.pid
      n=0
      while [ "$n" -lt 3 ]; do
        n=$((n + 1))
        ${pkgs.openssh}/bin/sshd -f ${sshdDir}/sshd_config >> ${sshdDir}/up.log 2>&1
        $core/sleep 1
        if alive ${sshdDir}/sshd.pid; then
          echo "[up $(date 2>/dev/null)] sshd started (attempt $n)" >> ${sshdDir}/up.log
          break
        fi
        $core/sleep 2
      done
      if ! alive ${sshdDir}/sshd.pid; then
        echo "[up $(date 2>/dev/null)] sshd FAILED after 3 attempts" >> ${sshdDir}/up.log
      fi
    fi

    # 2) reverse tunnel (requires the key set at bootstrap)
    if alive ${sshdDir}/tunnel.pid; then
      :
    elif [ -f ${relayKey} ]; then
      $core/rm -f ${sshdDir}/tunnel.pid
      $core/nohup ${tunnelLoop}/bin/phone-tunnel-loop >> ${sshdDir}/tunnel.log 2>&1 &
      echo $! > ${sshdDir}/tunnel.pid
    fi

    # 2b) WebSocket tunnel (wstunnel): independent of the SSH tunnel, it is the
    # path that passes a network that only lets out 443, and it also carries
    # the SOCKS5/HTTP proxies that exit with the phone's IP.
    if alive ${sshdDir}/wstunnel.pid; then
      :
    else
      $core/rm -f ${sshdDir}/wstunnel.pid
      $core/nohup ${wsLoop}/bin/phone-wstunnel-loop >> ${sshdDir}/wstunnel.log 2>&1 &
      echo $! > ${sshdDir}/wstunnel.pid
    fi

    # 3) watchdog: replays phone-up in a loop (restarts what is dead)
    if alive ${sshdDir}/watchdog.pid; then
      :
    else
      $core/rm -f ${sshdDir}/watchdog.pid
      $core/nohup ${phoneWatchdog}/bin/phone-watchdog >> ${sshdDir}/watchdog.log 2>&1 &
      echo $! > ${sshdDir}/watchdog.pid
    fi

    # 4) wake lock (Android anti-sleep; "pop-up windows" permission required).
    # DETACHED (nohup, never waited on): the am call can freeze endlessly (experienced:
    # `timeout 8` does not kill it, it held up.lock forever and silently
    # blocked ALL subsequent relaunches).
    wl=/nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/termux-wake-lock
    if [ -x "$wl" ]; then
      $core/nohup "$wl" >/dev/null 2>&1 &
    fi
  '';

  phoneWatchdog = pkgs.writeScriptBin "phone-watchdog" ''
    #!${pkgs.runtimeShell}
    while true; do
      ${pkgs.coreutils}/bin/sleep 120
      /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/phone-up || true
    done
  '';

  phoneUpdate = pkgs.writeScriptBin "phone-update" ''
    #!${pkgs.runtimeShell}
    export PATH=/nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin:$PATH
    cd ${home}
    exec nix-on-droid switch --flake "git+https://github.com/MarcPartensky/nixos" --option tarball-ttl 0
  '';

  phoneStatus = pkgs.writeScriptBin "phone-status" ''
    #!${pkgs.runtimeShell}
    check() {
      if [ -f "$2" ] && kill -0 "$(cat "$2" 2>/dev/null)" 2>/dev/null; then
        echo "$1: UP (pid $(cat "$2"))"
      else
        echo "$1: DOWN"
      fi
    }
    check sshd ${sshdDir}/sshd.pid
    check tunnel ${sshdDir}/tunnel.pid
    check watchdog ${sshdDir}/watchdog.pid
    check wstunnel ${sshdDir}/wstunnel.pid
    echo "== tunnel.log (5 dernieres lignes)"
    ${pkgs.coreutils}/bin/tail -n 5 ${sshdDir}/tunnel.log 2>/dev/null || true
    echo "== up.log (5 dernieres lignes)"
    ${pkgs.coreutils}/bin/tail -n 5 ${sshdDir}/up.log 2>/dev/null || true
    echo "== wstunnel.log (5 dernieres lignes)"
    ${pkgs.coreutils}/bin/tail -n 5 ${sshdDir}/wstunnel.log 2>/dev/null || true
  '';

  # Provisioning/repair of the device in one command. The file is the
  # exact copy of the artifact published behind the short link
  # (https://x.gd/a6gpx -> s.marcpartensky.com/nod -> Nextcloud); patchShebangs
  # replaces its `#!/bin/sh` with the store interpreter, like the other
  # scripts of the module.
  nodBootstrap = pkgs.runCommandLocal "nod-bootstrap" { } ''
    install -D -m 0755 ${./nod-bootstrap.sh} $out/bin/nod-bootstrap
  '';
in
{
  # Device ports. Default values = those of the phone; each
  # flake instance overrides them to avoid fighting with the other devices.
  options.nod-access = {
    relayPort = lib.mkOption {
      type = lib.types.port;
      default = 2224;
      description = ''
        Port of the reverse relay on the VPS loopback. The restricted
        authorized_keys entry of the VPS must have permitlisten="127.0.0.1:<port>".
      '';
    };
    wsSshdPort = lib.mkOption {
      type = lib.types.port;
      default = 2225;
    };
    wsSocksPort = lib.mkOption {
      type = lib.types.port;
      default = 1081;
    };
    wsHttpPort = lib.mkOption {
      type = lib.types.port;
      default = 1082;
    };
  };

  config = {
    environment.packages = with pkgs; [
      openssh
      util-linux # flock for phone-up
      gnugrep # handy in a debug session
      tunnelLoop # referenced here -> installed on the phone
      wsLoop
      wsTunnelPkg # WebSocket tunnel client (10.x, cf. comment in the let)
      phoneUp
      phoneWatchdog
      phoneUpdate
      phoneStatus
      nodBootstrap # (re)provisions the device: switch + phone-up + verification
    ];

    android-integration = {
      termux-wake-lock.enable = true;
      termux-wake-unlock.enable = true;
      termux-setup-storage.enable = true;
      termux-open.enable = true;
      termux-open-url.enable = true;
      am.enable = true;
    };

    build.activation = {
      sshd = ''
        $DRY_RUN_CMD mkdir -p ${sshdDir}
        if [ ! -f ${sshdDir}/ssh_host_ed25519_key ]; then
          $VERBOSE_ECHO "phone: generating sshd host key"
          $DRY_RUN_CMD ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f ${sshdDir}/ssh_host_ed25519_key
        fi
        $VERBOSE_ECHO "phone: installing sshd_config + authorized_keys"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p ${home}/.ssh
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod 700 ${home}/.ssh
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m 600 ${sshdConfig} ${sshdDir}/sshd_config
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m 600 ${authorizedKeysFile} ${home}/.ssh/authorized_keys
      '';

      termuxProps = ''
        $DRY_RUN_CMD mkdir -p ${home}/.termux
        if [ -z "''${DRY_RUN:-}" ]; then
          if ! grep -qs allow-external-apps ${home}/.termux/termux.properties; then
            printf 'allow-external-apps=true\n' >> ${home}/.termux/termux.properties
          fi
        fi
      '';

      autostart = ''
        if [ -z "''${DRY_RUN:-}" ]; then
          for f in ${home}/.zprofile ${home}/.zshrc ${home}/.profile ${home}/.bashrc; do
            if ! grep -q nod-phone-autostart2 "$f" 2>/dev/null; then
              printf '\n# nod-phone-autostart2\nif [ -x /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/phone-up ]; then /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/phone-up >/dev/null 2>&1 || true; fi\n' >> "$f"
            fi
          done
          if ! grep -q nod-phone-autorepair3 ${home}/.zshrc 2>/dev/null; then
            printf '\n# nod-phone-autorepair3\nalias up="phone-up"\n_nod_autorepair() {\n  local p=/nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/phone-up\n  [ -x "$p" ] || return 0\n  local s="$HOME/sshd/.up-stamp" now last\n  now=$(date +%s 2>/dev/null) || return 0\n  last=0\n  [ -f "$s" ] && last=$(stat -c %%Y "$s" 2>/dev/null || echo 0)\n  if [ "$((now - last))" -gt 60 ]; then\n    : > "$s"\n    ( "$p" >/dev/null 2>&1 & )\n  fi\n}\nprecmd_functions+=(_nod_autorepair)\n' >> ${home}/.zshrc
          fi
        fi
      '';
    };
  };
}
