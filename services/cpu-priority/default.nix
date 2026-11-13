# Priorité CPU/IO des charges de fond, et plafonds des jobs winnie.
#
# Deux étages :
#  1. `background.slice` (poids CPU/IO bas) : les batches cèdent le pas au
#     bureau et aux sessions Hermes sous concurrence, sans plafond quand la
#     machine est libre.
#  2. Plafonds CPUQuota déclaratifs sur les jobs winnie (la valeur sûre) +
#     `winnie-cpu-governor` qui les élargit à 1200 % (sauf les jobs navigateur,
#     plafonnés dur à 30 % du total) tant que la pression CPU
#     de user.slice (sessions de marc + Hermes) reste quasi nulle pendant
#     2 min, et les referme dès qu'une tâche interactive attend du CPU. Les
#     overrides passent par `systemctl set-property --runtime` (rien dans
#     /etc, un reboot ramène aux valeurs déclaratives, et si le gouverneur
#     s'arrête on reste borné).
#
# Mesuré le 25/10/2026 : un plat estimé par le modèle vision (qwen3-vl:4b,
# service winnie-calories) prenait ~790 % de CPU, soit la moitié de la
# 4800H, et Tctl montait à 100 °C.
{ pkgs, ... }:
{
  # Sessions desktop Hermes (utilisateur hermes, uid 988) : elles ne peuvent pas
  # entrer dans hermes.slice (cpuset root partition : une session logind ne
  # franchit pas la frontière d'hiérarchie), donc elles tournent sur les 16
  # threads au poids 100, à égalité avec le bureau de marc. Mesuré le
  # 12/11/2026 : 199 % + 18 % d'un cœur sur deux sessions desktop, load 25-33.
  # Un POIDS bas ne les bride pas machine libre ; sous concurrence le bureau de
  # marc obtient 4/5 du CPU au lieu d'1/2. Idem IO (builds, scans de store).
  # Le travail lourd des agents reste à router vers taskq ou un scope de fond.
  systemd.slices."user-988" = {
    description = "Sessions Hermes (poids bas sous concurrence)";
    sliceConfig = {
      CPUWeight = 25;
      IOWeight = 25;
    };
  };

  systemd.slices.background = {
    description = "Charges de fond (poids CPU/IO bas)";
    sliceConfig = {
      CPUWeight = 20;
      IOWeight = 20;
      # Réservation matérielle pour l'interactif : les deux threads du cœur
      # physique 6 (cpu12 et cpu13) sont réservés à hermes.slice. Un build,
      # même à 14 threads, ne peut pas les toucher : c'est un plancher, pas
      # un partage. Le poids ci-dessus arbitre le reste.
      AllowedCPUs = "0-11,14-15";
    };
  };

  # Émulateur Android (capture) : le plus gros consommateur unitaire mesuré
  # (124 % d'un cœur), et il vivait dans system.slice au poids 100, à égalité
  # avec le gateway. Il descend en fond avec un plafond dur.
  systemd.services.android-emulator.serviceConfig = {
    Slice = "background.slice";
    CPUQuota = "400%";
  };

  # Modèle vision local (qwen3-vl:4b) + embeddings mem0.
  systemd.services.ollama = {
    serviceConfig = {
      Slice = "background.slice";
      # Plafond sûr : 6 coeurs sur 16. Le gouverneur le monte à 12 quand
      # personne n'attend du CPU.
      CPUQuota = "600%";
      Nice = 10;
    };
    environment = {
      # 8 threads max (8c/16t) : au-delà le modèle se dispute la L3.
      OLLAMA_NUM_THREADS = "8";
      OLLAMA_KEEP_ALIVE = "5m";
    };
  };

  # Tout build lancé par un client nix passe par le démon.
  systemd.services.nix-daemon.serviceConfig.Slice = "background.slice";

  # Batches winnie : jamais prioritaires sur l'interactif, et plafonnés.
  # 400 % = 4 coeurs au pire ; le gouverneur élargit à 12 quand marc ne
  # travaille pas. Les unités transitoires winnie-job-* sont traitées pareil
  # par le gouverneur (400 -> 1200 %).
  systemd.services.winnie-calories.serviceConfig = {
    Slice = "background.slice";
    CPUQuota = "400%";
  };

  # Jobs navigateur (chromium/renderer : gmaps, ingest nightly, hours refresh).
  # Plafond DUR de 30 % du CPU total (480 % de 1600 % : 4,8 coeurs sur 16
  # threads, demande marc du 25/10/2026) : le gouverneur ne les élargit jamais
  # (HARD_CAP dans governor.py, qui rattrape aussi un override --runtime
  # périmé). Slice dédiée -> plafond COLLECTIF quand deux batchs se chevauchent
  # (nuit : nightly + gmaps). restartIfChanged=false : un switch ne tue pas un
  # batch navigateur en cours, la config s'applique au prochain démarrage.
  systemd.slices.winnie-browser = {
    description = "Jobs navigateur winnie (plafond 30 % du CPU total)";
    sliceConfig = {
      CPUQuota = "480%";
      CPUWeight = 20;
      IOWeight = 20;
    };
  };
  systemd.services.winnie-gmaps-scrape = {
    restartIfChanged = false;
    serviceConfig = {
      Slice = "winnie-browser.slice";
      CPUQuota = "480%";
    };
  };
  systemd.services.winnie-ingest-nightly = {
    restartIfChanged = false;
    serviceConfig = {
      Slice = "winnie-browser.slice";
      CPUQuota = "480%";
    };
  };
  systemd.services.winnie-hours-refresh = {
    restartIfChanged = false;
    serviceConfig = {
      Slice = "winnie-browser.slice";
      CPUQuota = "480%";
    };
  };

  # Gouverneur : élargit les plafonds quand les sessions de marc ne font pas
  # la queue pour du CPU, les restaure dès qu'elles en ont besoin. L'état vit
  # dans /run (le script crée le dossier) : reboot = retour aux plafonds
  # déclaratifs.
  systemd.services.winnie-cpu-governor = {
    description = "Gouverneur CPU des jobs winnie (capped/wide selon la pression de user.slice)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${./governor.py}";
    };
  };

  systemd.timers.winnie-cpu-governor = {
    description = "Tick du gouverneur CPU winnie (15 s)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "90s";
      OnUnitActiveSec = "15s";
      AccuracySec = "3s";
      Unit = "winnie-cpu-governor.service";
    };
  };
}
