{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.monero-miner;

  # XMRig est pilote par la ligne de commande : pas de fichier de config a
  # generer, donc rien a synchroniser dans /etc et aucun secret sur disque.
  args =
    [
      "--url=${cfg.pool}"
      "--user=${cfg.wallet}"
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

  # Plafond de charge batterie : le controleur steamdeck_hwmon expose
  # max_battery_charge_level (0 = pas de plafond, 80 = charge a 80 %). Le
  # chemin hwmonN varie selon l'ordre de detection, d'ou la recherche par nom.
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
            echo "steamdeck: charge limitee a ''${limit}% ($h)"
            found=1
          fi
        done
        [ "$found" -eq 1 ] || echo "steamdeck: max_battery_charge_level absent, plafond non applique"
      '';
    };

  # Surveille la temperature Tctl (k10temp) et gele/degele XMRig avec
  # SIGSTOP/SIGCONT. SIGSTOP plutot qu'un arret : le dataset RandomX reste en
  # memoire, la reprise est immediate et le pool retrouve le worker au lieu de
  # repartir de zero.
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
        echo "thermal: pause a ''${temp}mC"
      elif [ "$temp" -le ${toString (cfg.thermalGuard.resumeTemperature * 1000)} ] && [ -e "$flag" ]; then
        systemctl kill --signal=SIGCONT monero-miner.service && rm -f "$flag"
        echo "thermal: reprise a ''${temp}mC"
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
      description = "Paquet XMRig a utiliser.";
    };

    wallet = lib.mkOption {
      type = lib.types.str;
      example = "48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWZgDJRh3jpbZ7knX2aMVJpXyF5bZ1...";
      description = ''
        Adresse Monero qui recoit les gains. Une adresse principale (commence
        par 4) ou une sous-adresse (commence par 8) fait 95 caracteres.
      '';
    };

    pool = lib.mkOption {
      type = lib.types.str;
      default = "moneroocean.stream:443";
      description = "Endpoint Stratum du pool, au format host:port.";
    };

    poolPassword = lib.mkOption {
      type = lib.types.str;
      default = "x";
      description = "Mot de passe/envoye au pool (la plupart ignorent sa valeur).";
    };

    tls = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Active TLS vers le pool (le port 443 de MoneroOcean le supporte).";
    };

    threads = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = ''
        Nombre de threads RandomX. Sur le Steam Deck (4 coeurs Zen 2, 4 Mo de
        L3), 4 threads suffisent a saturer les coeurs physiques ; 8 threads
        (SMT) donnent le hashrate maximal au prix de plus de chaleur.
      '';
    };

    hugePages = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Reserve des huge pages 2 Mo pour RandomX (gain jusqu'a 50 %).";
    };

    hugePagesCount = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1280;
      description = ''
        Nombre de pages de 2 Mo reservees au boot. 1280 = 2,5 Gio : 2080 Mo de
        dataset + 256 Mo de cache + 16 Mo de scratchpads (8 threads) + marge.
      '';
    };

    pauseOnBattery = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Met le minage en pause quand la machine est sur batterie.";
    };

    rigId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Identifiant de la machine affiche dans les stats du pool.";
    };

    donateLevel = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 1;
      description = "Pourcentage de temps donne au developpeur de XMRig.";
    };

    printTime = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Intervalle (secondes) des rapports de hashrate dans le journal.";
    };

    cpuQuota = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Plafond CPU en pourcentage (100 % = un coeur). 300 laisse un coeur
        libre pour l'interface Steam et les jeux.
      '';
    };

    nice = lib.mkOption {
      type = lib.types.ints.between (-20) 19;
      default = 19;
      description = "Priorite CPU du processus (19 = la plus basse).";
    };

    chargeLimit = lib.mkOption {
      type = lib.types.nullOr (lib.types.ints.between 50 100);
      default = null;
      description = ''
        Plafond de charge de la batterie en pourcentage, applique au controleur
        steamdeck_hwmon s'il expose max_battery_charge_level. Utile pour un
        appareil qui mine branche en permanence. null = pas de plafond.
      '';
    };

    thermalGuard = {
      enable = lib.mkEnableOption "la mise en pause du mineur au-dela d'une temperature CPU";

      maxTemperature = lib.mkOption {
        type = lib.types.ints.positive;
        default = 85;
        description = "Temperature (C) a laquelle le mineur est mis en pause (SIGSTOP).";
      };

      resumeTemperature = lib.mkOption {
        type = lib.types.ints.positive;
        default = 75;
        description = "Temperature (C) a laquelle le mineur reprend (SIGCONT).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.wallet != "";
        message = "services.monero-miner.wallet doit contenir une adresse Monero.";
      }
      {
        assertion = (builtins.match "[48][1-9A-HJ-NP-Za-km-z]{94}" cfg.wallet) != null;
        message = ''
          services.monero-miner.wallet n'a pas la forme d'une adresse Monero
          standard ou de sous-adresse (95 caracteres, commence par 4 ou 8).
        '';
      }
      {
        assertion = cfg.thermalGuard.resumeTemperature < cfg.thermalGuard.maxTemperature;
        message = "services.monero-miner.thermalGuard.resumeTemperature doit etre inferieure a maxTemperature.";
      }
    ];

    boot.kernel.sysctl = lib.mkIf cfg.hugePages {
      "vm.nr_hugepages" = cfg.hugePagesCount;
    };

    systemd.services.monero-miner = {
      description = "XMRig Monero CPU miner";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/xmrig ${lib.escapeShellArgs args}";

        # Utilisateur jetable : aucun fichier, aucun home, aucun droit persistant.
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = 15;
        KillSignal = "SIGINT";
        TimeoutStopSec = 30;

        # Priorite basse et plafond : le Deck reste utilisable pendant le minage.
        Nice = cfg.nice;
        CPUSchedulingPolicy = "batch";
        CPUWeight = 20;
        CPUQuota = "${toString cfg.cpuQuota}%";
        IOSchedulingClass = "idle";
        OOMScoreAdjust = 500;

        # RandomX alloue le dataset en huge pages et peut verrouiller la memoire.
        LimitMEMLOCK = "infinity";

        # Durcissement. Ne PAS activer MemoryDenyWriteExecute : le JIT de
        # RandomX a besoin de pages a la fois executables et modifiables.
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
      description = "Plafond de charge batterie (Steam Deck)";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${chargeLimitScript cfg.chargeLimit}/bin/steamdeck-battery-charge-limit";
      };
    };

    systemd.services.monero-miner-thermal-guard = lib.mkIf cfg.thermalGuard.enable {
      description = "Pause XMRig si le CPU depasse le seuil thermique";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${thermalGuardScript}/bin/monero-miner-thermal-guard";
        Nice = 19;
      };
    };

    systemd.timers.monero-miner-thermal-guard = lib.mkIf cfg.thermalGuard.enable {
      description = "Surveillance thermique du mineur Monero";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "15s";
        AccuracySec = "5s";
        Unit = "monero-miner-thermal-guard.service";
      };
    };

    # Permet de lancer `xmrig --bench=1M` a la main pour comparer les reglages.
    environment.systemPackages = [ cfg.package ];
  };
}
