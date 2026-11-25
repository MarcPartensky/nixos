{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.hermesFallback;
in {
  # ==========================================================================
  # Hermes fallback on the LAPTOP, when tower is unreachable.
  #
  # Principle: the laptop runs a second gateway, installed but
  # STOPPED at boot (empty wantedBy, cf. profiles/laptop). Three pieces:
  #
  #   1. hermes-fallback-sync (daily timer): copies the agent state
  #      (state.db, memories, skills, sessions) from tower to the laptop. The
  #      sqlite database is copied by `sqlite3 .backup` on tower, so consistent
  #      even if the agent writes during the copy (no pqbox archive: those
  #      are decryptable only by marc's private key).
  #   2. hermes-fallback-watch (every 60 s): probes tower (SSH port of the
  #      tailnet then ICMP). After 5 consecutive failures (~5 min) it starts
  #      hermes-agent locally. It never stops it on its own: a return of
  #      tower must not cut an ongoing session.
  #   3. nginx on the tailnet IP: makes the local gateway reachable by a
  #      Pangolin resource (no port open outside the tailnet).
  #
  # What is deliberately NOT replicated: the Matrix/Discord token (two
  # gateways with the same token would compete for the connection: the fallback
  # talks through the webapp and the API), and the cron tasks (they would fire
  # twice and some target tower).
  # ==========================================================================
  options.services.hermesFallback = {
    enable = lib.mkEnableOption "the Hermes fallback on the laptop (state sync + automatic failover)";

    towerHost = lib.mkOption {
      type = lib.types.str;
      default = "tower";
      description = "SSH alias of tower in ~hermes/.ssh/config (source of the state).";
    };

    towerIp = lib.mkOption {
      type = lib.types.str;
      default = "100.64.0.3";
      description = "Tailnet IP of tower, probed by the watchdog.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "100.64.0.4";
      description = "Tailnet IP of the laptop, on which nginx publishes the fallback gateway.";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 9124;
      description = "nginx port of the fallback gateway (mirror of tower: 9124 -> 9123).";
    };

    gatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 9123;
      description = "Port of the local hermes-agent gateway (loopback bind).";
    };

    failureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Number of consecutive failed probes before failover (5 x 60 s = 5 min).";
    };

    syncOnCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:40:00";
      description = "Time of the state copy from tower (after the 03:10 pqbox backup).";
    };
  };

  config = lib.mkIf cfg.enable {
    # --- network probe: bash /dev/tcp + ping ---
    systemd.services.hermes-fallback-watch = {
      description = "Hermes fallback: probes tower and switches the gateway to local";
      after = ["network-online.target" "tailscaled.service"];
      wants = ["network-online.target"];
      path = [pkgs.bash pkgs.iputils pkgs.systemd];
      serviceConfig = {
        Type = "oneshot";
        # root: the only way to `systemctl start hermes-agent` (system unit).
        User = "root";
        StateDirectory = "hermes/fallback";
        StateDirectoryMode = "0750";
      };
      script = ''
        set -uo pipefail
        state=/var/lib/hermes/fallback
        mkdir -p "$state"
        fails=$(cat "$state/fails" 2>/dev/null || echo 0)
        up=0

        # Probe 1: tower SSH port on the tailnet (the most reliable, no ICMP
        # to filter). A connection refusal still means the host is
        # alive, so a failure is only counted on a TIMEOUT.
        if timeout 5 bash -c "exec 3<>/dev/tcp/${cfg.towerIp}/22" 2>/dev/null; then
          up=1
        else
          # Probe 2: ICMP, to distinguish "host off" from "sshd dead".
          if ping -c1 -W3 ${cfg.towerIp} >/dev/null 2>&1; then
            up=1
          fi
        fi

        if [ "$up" -eq 1 ]; then
          if [ "$fails" -ne 0 ]; then
            echo "tower reachable again, counter reset to zero"
            echo 0 > "$state/fails"
          fi
          exit 0
        fi

        fails=$((fails + 1))
        echo "$fails" > "$state/fails"
        echo "tower unreachable (${cfg.towerIp}), failure $fails/${toString cfg.failureThreshold}"

        if [ "$fails" -ge ${toString cfg.failureThreshold} ]; then
          if systemctl is-active --quiet hermes-agent.service; then
            echo "failover already done: hermes-agent is running locally"
          else
            echo "FAILOVER: starting the fallback gateway on the laptop"
            systemctl start hermes-agent.service || echo "failed to start hermes-agent"
            printf '%s automatic failover (tower unreachable for %s probes)\n' \
              "$(date -Is)" "$fails" >> "$state/journal.log"
          fi
        fi
      '';
    };

    systemd.timers.hermes-fallback-watch = {
      description = "Probes tower every 60 s (Hermes fallback)";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "60s";
        AccuracySec = "5s";
        Unit = "hermes-fallback-watch.service";
      };
    };

    # --- state copy from tower ---
    systemd.services.hermes-fallback-sync = {
      description = "Hermes fallback: copies the agent state from tower";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      path = [pkgs.openssh pkgs.rsync pkgs.coreutils pkgs.bash pkgs.systemd];
      # hermes: the key ~hermes/.ssh/id_ed25519 is already authorized on tower (it
      # also serves for pqbox backups), and the copied files belong to it.
      serviceConfig = {
        Type = "oneshot";
        User = "hermes";
        Group = "hermes";
        TimeoutStartSec = "1800";
      };
      script = ''
        set -euo pipefail
        home=/var/lib/hermes/.hermes
        mkdir -p "$home"

        # Never copy over a running agent: the database would be
        # replaced under the feet of the local process.
        if systemctl is-active --quiet hermes-agent.service; then
          echo "local agent active: copy skipped"
          exit 0
        fi

        # 1. consistent snapshot of the sqlite database, on tower (mode=ro)
        ssh -o BatchMode=yes -o ConnectTimeout=15 ${cfg.towerHost} python3 - <<'PY'
        import os
        import sqlite3

        src = "/var/lib/hermes/.hermes/state.db"
        dst = "/tmp/hermes-state-backup.db"
        if os.path.exists(dst):
            os.unlink(dst)
        con = sqlite3.connect("file:" + src + "?mode=ro", uri=True)
        out = sqlite3.connect(dst)
        con.backup(out)
        out.close()
        con.close()
        print("sqlite snapshot:", os.path.getsize(dst), "bytes")
        PY

        # 2. atomic pull (temporary file then rename)
        rsync -a --partial "${cfg.towerHost}:/tmp/hermes-state-backup.db" "$home/state.db.new"
        mv -f "$home/state.db.new" "$home/state.db"
        ssh -o BatchMode=yes ${cfg.towerHost} 'rm -f /tmp/hermes-state-backup.db'

        # 3. mirror directories (agent memory, skills, transcripts)
        for d in memories skills sessions; do
          rsync -a --delete --partial "${cfg.towerHost}:$home/$d/" "$home/$d/"
        done

        echo "copy OK: $(stat -c%s "$home/state.db") bytes of state.db"
      '';
    };

    systemd.timers.hermes-fallback-sync = {
      description = "Daily copy of the Hermes state from tower";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.syncOnCalendar;
        Persistent = true;
        RandomizedDelaySec = "10min";
        Unit = "hermes-fallback-sync.service";
      };
    };

    # --- publication of the fallback gateway on the tailnet ---
    # Bind on the tailnet IP only: nothing listens on the LAN or the web.
    # A Pangolin resource (hermes-secours.marcpartensky.com) can target
    # ${cfg.listenAddress}:${cfg.listenPort} from the VPS, which is in the tailnet.
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedGzipSettings = true;
      virtualHosts."hermes-fallback" = {
        listen = [
          {
            addr = cfg.listenAddress;
            port = cfg.listenPort;
          }
        ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.gatewayPort}";
          # the Hermes webapp opens a websocket for streaming responses
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
          '';
        };
      };
    };

    # --- control by the agent itself ---
    # The agent (hermes user) is the first that must check or trigger
    # the fallback. Without these rules it can only read the journal: starting the
    # fallback gateway would require marc on every test.
    security.sudo.extraRules = [
      {
        users = ["hermes"];
        commands = [
          {
            command = "/run/current-system/sw/bin/systemctl start hermes-agent";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl stop hermes-agent";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl restart hermes-agent";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl start hermes-fallback-sync";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    # Small state readable at a glance (probe counter, timers, gateway).
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "hermes-secours" ''
        set -u
        echo "failed tower probes: $(cat /var/lib/hermes/fallback/fails 2>/dev/null || echo 0)/${toString cfg.failureThreshold}"
        echo "local gateway: $(systemctl is-active hermes-agent.service 2>/dev/null || true)"
        echo "last state copy: $(stat -c %y /var/lib/hermes/.hermes/state.db 2>/dev/null || echo never)"
        systemctl list-timers 'hermes-fallback-*' --no-pager 2>/dev/null | sed -n '1,4p'
        tail -n 5 /var/lib/hermes/fallback/journal.log 2>/dev/null || true
      '')
    ];

    assertions = [
      {
        assertion = cfg.listenAddress != "0.0.0.0";
        message = "services.hermesFallback.listenAddress must be the tailnet IP, not 0.0.0.0";
      }
    ];
  };
}
