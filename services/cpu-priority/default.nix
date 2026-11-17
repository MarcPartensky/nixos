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

  # Ce que le gestionnaire utilisateur de hermes lance vit ICI : conteneurs
  # podman rootless, scopes `systemd-run --user`, jobs d'agents. Mesure du
  # 14/11/2026 : `immich_probe_ml` + `immich_probe_server` prenaient 5,1 + 3,6
  # = 8,8 coeurs au poids 100, soit exactement le poids du scope de session qui
  # porte l'event loop du backend desktop (0,38 coeur). Les deux se partageaient
  # donc les memes 14 threads a egalite : 294 gels d'event loop (max 114 s) et
  # 1461 `Timed out connecting to Hermes backend` cote client. Le gestionnaire
  # utilisateur descend a 10, et lui seul : la session interactive posee juste
  # au-dessus garde son poids, donc un index qui tourne ne peut plus passer
  # devant l'event loop qui sert la conversation.
  # `asDropin` : user@.service est un template systemd, un fichier complet le
  # remplacerait au lieu de le completer.
  systemd.services."user@988" = {
    overrideStrategy = "asDropin";
    # Ne JAMAIS redemarrer le gestionnaire utilisateur : il tuerait tout ce qui
    # vit sous lui (conteneurs rootless, scopes transitoires). Le poids
    # s'applique a sa prochaine creation, donc en pratique a la fin de toutes
    # les sessions ou au reboot.
    restartIfChanged = false;
    serviceConfig = {
      CPUWeight = 10;
      IOWeight = 10;
    };
  };

  # Indexeurs medias : batch par nature, jamais prioritaires sur l'interactif.
  # Le module nixpkgs place deja immich-server et immich-machine-learning dans
  # system-immich.slice, on ne fait que charger cette slice au lieu d'aller
  # chercher ses unites (evite un conflit de valeur sur `Slice`).
  # Plafond DUR de 6 coeurs sur 16, IO de fond, et plafond memoire SOUPLE :
  # `MemoryHigh` throttlee, `MemoryMax` aurait tue l'index en cours de scan,
  # c'est-a-dire exactement ce qu'on veut eviter.
  systemd.slices.system-immich.sliceConfig = {
    CPUQuota = "600%";
    CPUWeight = 20;
    IOWeight = 20;
    MemoryHigh = "12G";
  };

  # Memes plafonds poses AUSSI sur les deux unites, et pas seulement sur la
  # slice : une propriete de slice deja creee ne s'applique qu'a sa prochaine
  # creation, donc le plafond collectif n'aurait mordu qu'a un redemarrage
  # d'immich. Une propriete d'UNITE, elle, s'applique au switch (l'unite est
  # redemarree parce que son fichier a change). 300 % chacune = les 600 % de la
  # slice, mais effectifs dans la minute.
  systemd.services.immich-server.serviceConfig = {
    CPUQuota = "300%";
    IOWeight = 20;
    MemoryHigh = "6G";
  };
  systemd.services.immich-machine-learning.serviceConfig = {
    CPUQuota = "300%";
    IOWeight = 20;
    MemoryHigh = "6G";
  };

  # Second indexeur photo (hors immich), meme profil, plafond plus petit.
  systemd.slices.media-index = {
    description = "Indexeurs medias hors immich (photoprism)";
    sliceConfig = {
      CPUQuota = "400%";
      CPUWeight = 20;
      IOWeight = 20;
      MemoryHigh = "8G";
    };
  };
  systemd.services.photoprism.serviceConfig.Slice = "media-index.slice";

  # Porte d'entree SSH : le maillon sans lequel aucun autre n'existe. Elle
  # vivait dans system.slice au poids 100, sans plancher memoire, avec la limite
  # de redemarrage par defaut (5 echecs en 10 s puis `failed` DEFINITIF, meme
  # avec Restart=always). Honnetete : `sshd-session`, le process qui chiffre
  # reellement le tunnel, reste dans le scope de session (logind), donc cette
  # protection couvre l'accept et la survie du listener, pas le debit du tunnel.
  systemd.slices.interactive = {
    description = "Portes d'entree interactives (sshd)";
    sliceConfig = {
      CPUWeight = 1500;
      IOWeight = 1000;
      MemoryMin = "256M";
    };
  };
  systemd.services.sshd = {
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Slice = "interactive.slice";
      OOMScoreAdjust = -900;
      MemoryMin = "128M";
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

  # Batches winnie : ORPHELINS depuis la sortie de Winnie de la conf hote
  # (13/11/2026, cf services/default.nix et deploy/winnie/README.md). Ces
  # quatre `systemd.services.winnie-*` ne portaient QUE des overrides
  # (Slice/CPUQuota), sans ExecStart : NixOS generait des unites systeme
  # invalides (`LoadError=BadUnitSetting`, invisibles de `systemctl --failed`,
  # cf. nixos-service-troubleshooting), et winnie-ingest-nightly ne tournait
  # plus du tout (son timer vivait dans le module winnie retire). Supprimes le
  # 17/11/2026 (reparation de nuit) : winnie-ingest-nightly est redeploye en
  # unite UTILISATEUR hermes (deploy/winnie/winnie-ingest-nightly.service,
  # meme pattern que backend/frontend/dev). winnie-calories, winnie-gmaps-scrape
  # et winnie-hours-refresh restent a reprendre pareil le jour ou ils seront
  # utiles (non fait ici : aucun binaire pret cote deploy/winnie pour eux).
  systemd.slices.winnie-browser = {
    description = "Jobs navigateur winnie (plafond 30 % du CPU total) — INUTILISEE depuis le 17/11/2026, winnie tourne hors conf hote";
    sliceConfig = {
      CPUQuota = "480%";
      CPUWeight = 20;
      IOWeight = 20;
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
