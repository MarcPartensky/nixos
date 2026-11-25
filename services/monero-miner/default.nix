{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.monero-miner;

  isTime = value: (builtins.match "(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]" value) != null;

  # XMRig is driven by the command line: no config file to
  # generate, so nothing to synchronize in /etc and no secret in the store.
  baseArgs =
    [
      "--url=${cfg.pool}"
      "--pass=${cfg.poolPassword}"
      "--coin=monero"
      "--threads=${toString cfg.threads}"
      "--keepalive"
      "--print-time=${toString cfg.printTime}"
      "--donate-level=${toString cfg.donateLevel}"
      "--no-color"
    ]
    ++ lib.optionals cfg.tls [ "--tls" ]
    ++ lib.optionals (!cfg.hugePages) [ "--no-huge-pages" ]
    ++ lib.optionals cfg.pauseOnBattery [ "--pause-on-battery" ]
    ++ lib.optionals (cfg.rigId != "") [ "--rig-id=${cfg.rigId}" ];

  args = baseArgs ++ [ "--user=${cfg.wallet}" ];

  # When the wallet comes from sops, it is read from the systemd credential and
  # never appears in the command line or in the store.
  startScript = pkgs.writeShellApplication {
    name = "monero-miner-start";
    runtimeInputs = [ cfg.package pkgs.coreutils ];
    text = ''
      wallet="$(cat "''${CREDENTIALS_DIRECTORY}/wallet")"
      exec ${cfg.package}/bin/xmrig ${lib.escapeShellArgs baseArgs} --user="$wallet"
    '';
  };

  schedulerPython = pkgs.python3.withPackages (ps: [ ps.caldav ]);

  schedulerScript = pkgs.writeShellApplication {
    name = "monero-miner-scheduler";
    runtimeInputs = [ schedulerPython pkgs.systemd pkgs.coreutils ];
    text = ''
      exec ${schedulerPython}/bin/python3 ${./scheduler.py}
    '';
  };

  # Battery charge ceiling: the steamdeck_hwmon controller exposes
  # max_battery_charge_level (0 = no ceiling, 80 = charge to 80%). The
  # hwmonN path varies with the detection order, hence the search by name.
  chargeLimitScript = limit:
    pkgs.writeShellApplication {
      name = "steamdeck-battery-charge-limit";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        limit=${toString limit}
        found=0
        for h in /sys/class/hwmon/hwmon*; do
          [ -r "$h/name" ] || continue
          if [ "$(cat "$h/name")" = "steamdeck_hwmon" ] && [ -w "$h/max_battery_charge_level" ]; then
            echo "$limit" > "$h/max_battery_charge_level"
            echo "steamdeck: charge limited to ''${limit}% ($h)"
            found=1
          fi
        done
        [ "$found" -eq 1 ] || echo "steamdeck: max_battery_charge_level absent, ceiling not applied"
      '';
    };

  # Monitors the Tctl temperature (k10temp) and freezes/thaws XMRig with
  # SIGSTOP/SIGCONT. SIGSTOP rather than a stop: the RandomX dataset stays in
  # memory, the resume is immediate and the pool finds the worker again instead of
  # starting from scratch.
  thermalGuardScript = pkgs.writeShellApplication {
    name = "monero-miner-thermal-guard";
    runtimeInputs = [ pkgs.coreutils pkgs.systemd ];
    text = ''
      flag=/run/monero-miner-thermal.paused
      if ! systemctl is-active --quiet monero-miner.service; then
        rm -f "$flag"
        exit 0
      fi
      temp=
      for h in /sys/class/hwmon/hwmon*; do
        if [ -r "$h/name" ] && [ "$(cat "$h/name")" = "k10temp" ] && [ -r "$h/temp1_input" ]; then
          temp=$(cat "$h/temp1_input")
          break
        fi
      done
      if [ -z "$temp" ]; then
        temp=$(cat /sys/class/hwmon/hwmon*/temp*_input 2>/dev/null | sort -n | tail -n 1 || true)
      fi
      [ -n "$temp" ] || exit 0
      if [ "$temp" -ge ${toString (cfg.thermalGuard.maxTemperature * 1000)} ] && [ ! -e "$flag" ]; then
        systemctl kill --signal=SIGSTOP monero-miner.service && touch "$flag"
        echo "thermal: paused at ''${temp}mC"
      elif [ "$temp" -le ${toString (cfg.thermalGuard.resumeTemperature * 1000)} ] && [ -e "$flag" ]; then
        systemctl kill --signal=SIGCONT monero-miner.service && rm -f "$flag"
        echo "thermal: resumed at ''${temp}mC"
      fi
    '';
  };
in
{
  options.services.monero-miner = {
    enable = lib.mkEnableOption "XMRig Monero CPU miner";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.xmrig;
      defaultText = lib.literalExpression "pkgs.xmrig";
      description = "XMRig package to use.";
    };

    wallet = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWZgDJRh3jpbZ7knX2aMVJpXyF5bZ1...";
      description = ''
        Monero address that receives the earnings. A main address (starts
        with 4) or a subaddress (starts with 8) is 95 characters.
        Leave empty if walletFile is used.
      '';
    };

    walletFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a file containing the Monero address, typically a sops secret
        read by systemd via LoadCredential. Takes precedence over wallet.
      '';
    };

    schedule = {
      enable = lib.mkEnableOption "the mining schedule";

      weekdayStart = lib.mkOption {
        type = lib.types.str;
        default = "01:00";
        description = "Start of the weekday sleep window (HH:MM).";
      };

      weekdayWorkStart = lib.mkOption {
        type = lib.types.str;
        default = "09:00";
        description = "Time from which the calendar decides on weekdays (HH:MM).";
      };

      weekdayEnd = lib.mkOption {
        type = lib.types.str;
        default = "18:00";
        description = "End of the weekday window (HH:MM).";
      };

      weekendStart = lib.mkOption {
        type = lib.types.str;
        default = "01:00";
        description = "Start of the weekend window (HH:MM).";
      };

      weekendEnd = lib.mkOption {
        type = lib.types.str;
        default = "09:00";
        description = "End of the weekend window (HH:MM).";
      };
    };

    calendar = {
      enable = lib.mkEnableOption "the restriction to Nextcloud work events";

      url = lib.mkOption {
        type = lib.types.str;
        default = "https://cloud.marcpartensky.com";
        description = "Nextcloud CalDAV base URL.";
      };

      userFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "File containing the Nextcloud username.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "File containing the Nextcloud password or app password.";
      };

      calendars = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "sg" ];
        description = "Calendars whose active event authorizes mining.";
      };

      failOpen = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Mine during the work window if the calendar is unavailable.";
      };
    };

    pool = lib.mkOption {
      type = lib.types.str;
      default = "gulf.moneroocean.stream:10008";
      description = "Stratum endpoint of the pool, in host:port format.";
    };

    poolPassword = lib.mkOption {
      type = lib.types.str;
      default = "x";
      description = "Password sent to the pool (most ignore its value).";
    };

    tls = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enables TLS to the pool. MoneroOcean does not offer it on its Stratum
        port (unlike its HTTPS dashboard); leave false for it.
        Stratum only carries the public wallet address.
      '';
    };

    threads = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = ''
        Number of RandomX threads. On the Steam Deck (4 Zen 2 cores, 4 MB of
        L3), 4 threads are enough to saturate the physical cores; 8 threads
        (SMT) give the maximum hashrate at the cost of more heat.
      '';
    };

    hugePages = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Reserves 2 MB huge pages for RandomX (gain up to 50%).";
    };

    hugePagesCount = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1280;
      description = ''
        Number of 2 MB pages reserved at boot. 1280 = 2.5 GiB: 2080 MB of
        dataset + 256 MB of cache + 16 MB of scratchpads (8 threads) + margin.
      '';
    };

    pauseOnBattery = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Pauses mining when the machine is on battery.";
    };

    rigId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Machine identifier shown in the pool stats.";
    };

    donateLevel = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 1;
      description = "Percentage of time given to the XMRig developer.";
    };

    printTime = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Interval (seconds) of the hashrate reports in the log.";
    };

    cpuQuota = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        CPU ceiling in percent (100% = one core). 300 leaves one core
        free for the Steam interface and games.
      '';
    };

    nice = lib.mkOption {
      type = lib.types.ints.between (-20) 19;
      default = 19;
      description = "CPU priority of the process (19 = the lowest).";
    };

    chargeLimit = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 50 100);
      default = null;
      description = ''
        Battery charge ceiling in percent, applied to the steamdeck_hwmon
        controller if it exposes max_battery_charge_level. Useful for a
        device that mines plugged in permanently. null = no ceiling.
      '';
    };

    thermalGuard = {
      enable = lib.mkEnableOption "pausing the miner above a CPU temperature";

      maxTemperature = lib.mkOption {
        type = lib.types.ints.positive;
        default = 85;
        description = "Temperature (C) at which the miner is paused (SIGSTOP).";
      };

      resumeTemperature = lib.mkOption {
        type = lib.types.ints.positive;
        default = 75;
        description = "Temperature (C) at which the miner resumes (SIGCONT).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.wallet != "" || cfg.walletFile != null;
        message = "services.monero-miner.wallet or walletFile must be set.";
      }
      {
        assertion = cfg.wallet == "" || (builtins.match "[48][1-9A-HJ-NP-Za-km-z]{94}" cfg.wallet) != null;
        message = ''
          services.monero-miner.wallet does not have the form of a standard
          Monero address or subaddress (95 characters, starts with 4 or 8).
        '';
      }
      {
        assertion = lib.all isTime [
          cfg.schedule.weekdayStart
          cfg.schedule.weekdayWorkStart
          cfg.schedule.weekdayEnd
          cfg.schedule.weekendStart
          cfg.schedule.weekendEnd
        ];
        message = "The times of services.monero-miner.schedule must be in HH:MM format.";
      }
      {
        assertion = !cfg.schedule.enable || !cfg.calendar.enable
          || (cfg.calendar.userFile != null && cfg.calendar.passwordFile != null);
        message = ''
          services.monero-miner.calendar.enable requires userFile and passwordFile
          (sops secrets) to query Nextcloud.
        '';
      }
      {
        assertion = cfg.thermalGuard.resumeTemperature < cfg.thermalGuard.maxTemperature;
        message = "services.monero-miner.thermalGuard.resumeTemperature must be lower than maxTemperature.";
      }
    ];

    boot.kernel.sysctl = lib.mkIf cfg.hugePages {
      "vm.nr_hugepages" = cfg.hugePagesCount;
    };

    systemd.services.monero-miner = {
      description = "XMRig Monero CPU miner";
      wantedBy = lib.optionals (!cfg.schedule.enable) [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        ExecStart =
          if cfg.walletFile != null
          then "${startScript}/bin/monero-miner-start"
          else "${cfg.package}/bin/xmrig ${lib.escapeShellArgs args}";

        # Disposable user: no file, no home, no persistent rights.
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = 15;
        KillSignal = "SIGINT";
        TimeoutStopSec = 30;
        LoadCredential = lib.optionals (cfg.walletFile != null) [
          "wallet:${cfg.walletFile}"
        ];

        # Low priority and ceiling: the Deck stays usable during mining.
        Nice = cfg.nice;
        CPUSchedulingPolicy = "batch";
        CPUWeight = 20;
        CPUQuota = "${toString cfg.cpuQuota}%";
        IOSchedulingClass = "idle";
        OOMScoreAdjust = 500;

        # RandomX allocates the dataset in huge pages and may lock the memory.
        LimitMEMLOCK = "infinity";

        # Hardening. Do NOT enable MemoryDenyWriteExecute: the RandomX JIT
        # needs pages that are both executable and writable.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = "AF_INET AF_INET6";
        RestrictNamespaces = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
      };
    };

    systemd.services.monero-miner-charge-limit = lib.mkIf (cfg.chargeLimit != null) {
      description = "Battery charge ceiling (Steam Deck)";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${chargeLimitScript cfg.chargeLimit}/bin/steamdeck-battery-charge-limit";
      };
    };

    systemd.services.monero-miner-thermal-guard = lib.mkIf cfg.thermalGuard.enable {
      description = "Pause XMRig if the CPU exceeds the thermal threshold";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${thermalGuardScript}/bin/monero-miner-thermal-guard";
        Nice = 19;
      };
    };

    systemd.timers.monero-miner-thermal-guard = lib.mkIf cfg.thermalGuard.enable {
      description = "Thermal monitoring of the Monero miner";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "15s";
        AccuracySec = "5s";
        Unit = "monero-miner-thermal-guard.service";
      };
    };

    systemd.services.monero-miner-scheduler = lib.mkIf cfg.schedule.enable {
      description = "Monero miner scheduler (Nextcloud calendar)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = {
        MONERO_SCHEDULE_WEEKDAY_START = cfg.schedule.weekdayStart;
        MONERO_SCHEDULE_WEEKDAY_WORK_START = cfg.schedule.weekdayWorkStart;
        MONERO_SCHEDULE_WEEKDAY_END = cfg.schedule.weekdayEnd;
        MONERO_SCHEDULE_WEEKEND_START = cfg.schedule.weekendStart;
        MONERO_SCHEDULE_WEEKEND_END = cfg.schedule.weekendEnd;
        MONERO_CALENDAR_ENABLE = if cfg.calendar.enable then "1" else "0";
        MONERO_CALENDAR_URL = cfg.calendar.url;
        MONERO_CALENDAR_USER_FILE =
          if cfg.calendar.userFile != null then cfg.calendar.userFile else "";
        MONERO_CALENDAR_PASSWORD_FILE =
          if cfg.calendar.passwordFile != null then cfg.calendar.passwordFile else "";
        MONERO_CALENDAR_NAMES = lib.concatStringsSep "," cfg.calendar.calendars;
        MONERO_CALENDAR_FAIL_OPEN = if cfg.calendar.failOpen then "1" else "0";
        MONERO_MINER_UNIT = "monero-miner.service";
        MONERO_SYSTEMCTL = "${pkgs.systemd}/bin/systemctl";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${schedulerScript}/bin/monero-miner-scheduler";
        TimeoutStartSec = 90;
      };
    };

    systemd.timers.monero-miner-scheduler = lib.mkIf cfg.schedule.enable {
      description = "Periodic application of the Monero miner schedule";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
        AccuracySec = "30s";
        Unit = "monero-miner-scheduler.service";
      };
    };

    # Allows running `xmrig --bench=1M` by hand to compare settings.
    environment.systemPackages = [ cfg.package ];
  };
}
