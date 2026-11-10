{ config, pkgs, lib, ... }:
# taskq : file de taches + ordonnanceur pour tower.
#
# Le dispatcher tourne en root (il lance des unites systeme), lit /proc pour
# savoir si marc travaille, et n'autorise une tache que si elle tient dans la
# machine. Les taches sont posees par le CLI `taskq` (systeme + agents).
let
  db = "postgresql://taskq@127.0.0.1/taskq";
  # Le dispatcher et le CLI importent presence.py, donc les deux fichiers
  # vivent cote a cote dans un meme dossier du store (writeTextFile ne sait
  # poser qu'un fichier a la fois). presence.py porte le modele de presence de
  # marc (fenetres sommeil/travail croisees avec les signaux reels).
  dispatcherSrc = pkgs.runCommand "taskq-dispatcher-src" { } ''
    mkdir -p $out
    cp ${./dispatcher.py} $out/dispatcher.py
    cp ${./presence.py} $out/presence.py
  '';
  cliSrc = pkgs.runCommand "taskq-cli-src" { } ''
    mkdir -p $out
    cp ${./taskq.py} $out/taskq.py
    cp ${./presence.py} $out/presence.py
  '';
  # Config de presence declarative : fenetres de sommeil et de travail (heure
  # de New York) lues par le dispatcher et le CLI. Les jours exceptionnels
  # (conge, teletravail) se posent par date sans rebuild, dans la table state
  # (cle presence_overrides) : `taskq presence off demain`, `taskq presence
  # wfh 2026-11-04`, `taskq presence clear demain`.
  presenceCfg = {
    tz = "America/New_York";
    sleep = { start = "02:30"; end = "08:30"; };
    work = { days = [ 1 2 3 4 5 ]; start = "09:00"; end = "18:30"; };
  };
  # API JSON + webui de la file (lecture + actions). Loopback uniquement ;
  # exposee par Pangolin (SSO) sur taskq.marcpartensky.com via newt.
  api = pkgs.writeTextFile {
    name = "taskq-api.py";
    executable = true;
    text = builtins.readFile ./api.py;
  };
  # Serveur MCP (stdio) : memes operations que le CLI et la webui, pour les
  # agents (submit/list/show/why/metrics/state/hosts/control/logs/digest/webui).
  mcp = pkgs.writers.writePython3Bin "taskq-mcp" {
    libraries = [ pkgs.python3Packages.mcp ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./mcp.py);
  schema = pkgs.writeText "taskq-schema.sql" (builtins.readFile ./schema.sql);
in
{
  # Config de presence (fenetres sommeil/travail) : lue par le dispatcher et
  # par `taskq presence`. Overrides par date : table state, cle
  # presence_overrides (pas de rebuild pour un jour de conge).
  environment.etc."taskq/presence.json".text = builtins.toJSON presenceCfg;

  # Utilisateur systeme pour les services taskq (le role Postgres homonyme est
  # declare juste en dessous: deux espaces de noms differents).
  users.groups.taskq = { };
  users.users.taskq = {
    isSystemUser = true;
    group = "taskq";
    description = "taskq queue services";
  };

  services.postgresql.ensureDatabases = [ "taskq" ];
  services.postgresql.ensureUsers = [
    {
      name = "taskq";
      ensureDBOwnership = true;
    }
  ];

  systemd.services.taskq-schema = {
    description = "Apply the taskq queue schema (idempotent)";
    requires = [ "postgresql-setup.service" ];
    after = [ "postgresql-setup.service" "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "taskq";
    };
    script = ''
      ${pkgs.postgresql}/bin/psql "${db}" -v ON_ERROR_STOP=1 -q -f ${schema}
    '';
  };

  systemd.services.taskq-dispatcher = {
    description = "taskq dispatcher (decide when heavy tasks may run)";
    after = [ "postgresql.service" "taskq-schema.service" "network-online.target" ];
    requires = [ "postgresql.service" "taskq-schema.service" ];
    wantedBy = [ "multi-user.target" ];
    # psql pour la file, systemd-run/systemctl pour lancer les taches,
    # sqlite3 pour lire l'activite des sessions Hermes (taches `needs_absence`).
    path = [ pkgs.postgresql pkgs.systemd pkgs.coreutils pkgs.sqlite ];
    environment = {
      TASKQ_DATABASE_URL = db;
      TASKQ_WINNIE_DATABASE_URL = "postgresql://winnie@127.0.0.1/winnie";
      # marc n'a pas d'uid explicite dans la config: l'option vaut null et
      # toString null donnerait "" (le dispatcher refusait de demarrer).
      TASKQ_MARC_UID =
        let uid = config.users.users.marc.uid;
        in if uid == null then "1000" else toString uid;
      TASKQ_RESERVE_MB = "3072";
      TASKQ_BUSY_CPU_PCT = "20";
      # Fenetre d'inactivite (minutes) des taches `needs_absence`: sans
      # interaction de marc (shell, session Hermes interactive, web UI) depuis
      # ce delai, elles demarrent; sa premiere interaction les interrompt.
      # S'y ajoutent les fenetres d'absence previsionnelles (presence.json) et
      # une hysteresis de calme de TASKQ_WINDOW_CALM_SECONDS avant un
      # redemarrage en fenetre.
      TASKQ_ABSENCE_MINUTES = "15";
      TASKQ_PRESENCE_CONFIG = "/etc/taskq/presence.json";
    };
    serviceConfig = {
      Type = "exec";
      ExecStart = "${pkgs.python3}/bin/python3 ${dispatcherSrc}/dispatcher.py";
      Restart = "always";
      RestartSec = 10;
    };
  };

  # taskq-api : API JSON + webui de la file (127.0.0.1:9077, voir le module
  # services/taskq). HTTP + SSO : l'API n'a pas d'authentification propre et
  # n'ecoute qu'en loopback derriere newt.
  systemd.services.taskq-api = {
    description = "taskq API + webui (queue read/actions)";
    after = [ "postgresql.service" "taskq-schema.service" ];
    requires = [ "postgresql.service" "taskq-schema.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.postgresql pkgs.coreutils ];
    environment = {
      TASKQ_DATABASE_URL = db;
      TASKQ_API_PORT = "9077";
    };
    serviceConfig = {
      Type = "exec";
      User = "taskq";
      ExecStart = "${pkgs.python3}/bin/python3 ${api}";
      Restart = "always";
      RestartSec = 10;
    };
  };

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "taskq" ''
      export PATH=${pkgs.postgresql}/bin:$PATH
      export TASKQ_DATABASE_URL=${db}
      exec ${pkgs.python3}/bin/python3 ${cliSrc}/taskq.py "$@"
    '')
  ];

  # Serveur MCP enregistre aupres de hermes (meme pattern que rustfs/roku : le
  # module hermes-agent est importe par profiles/common, l'option existe donc
  # partout ou ce module est charge). Les outils apparaissent dans une nouvelle
  # session apres le switch (le gateway ne redemarre pas tout seul).
  services.hermes-agent.mcpServers.taskq = {
    command = "${mcp}/bin/taskq-mcp";
    timeout = 120;
    env = {
      TASKQ_DATABASE_URL = db;
      TASKQ_PSQL = "${pkgs.postgresql}/bin/psql";
      TASKQ_JOURNALCTL = "${pkgs.systemd}/bin/journalctl";
      TASKQ_WEBUI_URL = "https://taskq.marcpartensky.com";
    };
  };
}
