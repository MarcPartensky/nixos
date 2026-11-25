{ config, pkgs, lib, ... }:
# taskq: task queue + scheduler for tower.
#
# The dispatcher runs as root (it launches system units), reads /proc to
# know whether marc is working, and only allows a task if it fits in the
# machine. Tasks are submitted by the `taskq` CLI (system + agents).
let
  db = "postgresql://taskq@127.0.0.1/taskq";
  # The dispatcher and the CLI import presence.py, so both files
  # live side by side in the same store folder (writeTextFile can only
  # place one file at a time). presence.py carries marc's presence model
  # (sleep/work windows crossed with the real signals).
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
  # Declarative presence config: sleep and work windows (New York
  # time) read by the dispatcher and the CLI. Exceptional days
  # (day off, remote work) are set by date without a rebuild, in the state
  # table (key presence_overrides): `taskq presence off demain`, `taskq presence
  # wfh 2026-11-04`, `taskq presence clear demain`.
  presenceCfg = {
    tz = "America/New_York";
    sleep = { start = "02:30"; end = "08:30"; };
    work = { days = [ 1 2 3 4 5 ]; start = "09:00"; end = "18:30"; };
  };
  # JSON API + queue webui (read + actions). Loopback only;
  # exposed by Pangolin (SSO) on taskq.marcpartensky.com via newt.
  api = pkgs.writeTextFile {
    name = "taskq-api.py";
    executable = true;
    text = builtins.readFile ./api.py;
  };
  # MCP server (stdio): same operations as the CLI and the webui, for the
  # agents (submit/list/show/why/metrics/state/hosts/control/logs/digest/webui).
  mcp = pkgs.writers.writePython3Bin "taskq-mcp" {
    libraries = [ pkgs.python3Packages.mcp ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./mcp.py);
  schema = pkgs.writeText "taskq-schema.sql" (builtins.readFile ./schema.sql);
in
{
  # Presence config (sleep/work windows): read by the dispatcher and
  # by `taskq presence`. Per-date overrides: state table, key
  # presence_overrides (no rebuild for a day off).
  environment.etc."taskq/presence.json".text = builtins.toJSON presenceCfg;

  # System user for the taskq services (the same-named Postgres role is
  # declared just below: two different namespaces).
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
    # psql for the queue, systemd-run/systemctl to launch the tasks,
    # sqlite3 to read the activity of Hermes sessions (`needs_absence` tasks).
    path = [ pkgs.postgresql pkgs.systemd pkgs.coreutils pkgs.sqlite ];
    environment = {
      TASKQ_DATABASE_URL = db;
      TASKQ_WINNIE_DATABASE_URL = "postgresql://winnie@127.0.0.1/winnie";
      # marc has no explicit uid in the config: the option is null and
      # toString null would give "" (the dispatcher refused to start).
      TASKQ_MARC_UID =
        let uid = config.users.users.marc.uid;
        in if uid == null then "1000" else toString uid;
      TASKQ_RESERVE_MB = "3072";
      TASKQ_BUSY_CPU_PCT = "20";
      # Inactivity window (minutes) of `needs_absence` tasks: with no
      # interaction from marc (shell, interactive Hermes session, web UI) for
      # this delay, they start; his first interaction interrupts them.
      # To this are added the predictive absence windows (presence.json) and
      # a calm hysteresis of TASKQ_WINDOW_CALM_SECONDS before a
      # restart within a window.
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

  # taskq-api: JSON API + queue webui (127.0.0.1:9077, see the module
  # services/taskq). HTTP + SSO: the API has no authentication of its own and
  # only listens on loopback behind newt.
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

  # MCP server registered with hermes (same pattern as rustfs/roku: the
  # hermes-agent module is imported by profiles/common, so the option exists
  # wherever this module is loaded). The tools appear in a new
  # session after the switch (the gateway does not restart by itself).
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
