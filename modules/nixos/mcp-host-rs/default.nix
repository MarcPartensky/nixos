{ config, lib, pkgs, ... }:
# Single MCP host (Rust): owns every stdio MCP server once and exposes their
# tools behind one Streamable HTTP endpoint. Hermes then holds one MCP
# connection instead of spawning 36 servers per session.
#
# Measured on tower (21/11/2026): 28 stdio servers declared, 26 start, 516
# tools, 1 host process at rest, children spawned on demand and reaped after
# `idleTimeout`. Two servers stay out on purpose (vaultwarden: missing
# client_id, codeberg: python-dotenv absent from its venv), see `exclude`.
#
# The binary is compiled on the laptop (never on tower, see build.sh in
# /var/lib/hermes/workspace/mcp-rust) and vendored here as a prebuilt file.
let
  cfg = config.services.mcp-host-rs;

  # JSON string syntax is also a valid TOML basic string.
  q = s: builtins.toJSON (toString s);

  renderServer = name: s: ''
    [[server]]
    name = ${q name}
    command = ${q s.command}
  ''
  + lib.optionalString ((s.args or [ ]) != [ ]) ''
    args = [ ${lib.concatMapStringsSep ", " q (s.args or [ ])} ]
  ''
  + lib.optionalString ((s.env or { }) != { }) ''
    env = { ${
      lib.concatStringsSep ", "
      (lib.mapAttrsToList (k: v: "${q k} = ${q v}") (s.env or { }))
    } }
  ''
  + "\n";

  hosted = lib.filterAttrs
    (n: v: (v.command or null) != null && !(lib.elem n cfg.exclude))
    config.services.hermes-agent.mcpServers;

  manifest = pkgs.writeText "mcp-host-servers.toml" (''
    [host]
    bind = "127.0.0.1:${toString cfg.port}"
    path = "/mcp"
    idle_timeout_s = ${toString cfg.idleTimeout}
    call_timeout_s = ${toString cfg.callTimeout}
    start_timeout_s = 60
  '' + lib.concatStrings (lib.mapAttrsToList renderServer hosted));

  package = pkgs.runCommand "mcp-host-rs" { } ''
    install -Dm0755 ${./mcp-host} $out/bin/mcp-host
  '';
in
{
  options.services.mcp-host-rs = {
    enable = lib.mkEnableOption "single MCP host (Rust) for Hermes";

    takeover = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Flip Hermes onto the single URL: adds the `mcp-host` entry and sets
        `enabled = false` on every hosted stdio server. Keep false until the
        host answers with the expected tool count.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 18090;
      description = "Loopback port. Never expose it: only Hermes talks to it.";
    };

    idleTimeout = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = "An MCP child idle for that many seconds is killed; the next call respawns it.";
    };

    callTimeout = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Per tool call budget, in seconds.";
    };

    exclude = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "vaultwarden" "codeberg" ];
      description = "Servers kept on stdio (broken before the migration).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.mcp-host-rs = {
      description = "Single MCP host (stdio servers owned once, one HTTP endpoint)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        MCP_HOST_MANIFEST = "${manifest}";
        HOME = "/var/lib/hermes";
        # Spawned children inherit this PATH: gitea-mcp and npx need it.
        PATH = "/run/current-system/sw/bin:/etc/profiles/per-user/hermes/bin:/var/lib/hermes/.local/bin";
      };

      serviceConfig = {
        ExecStart = "${package}/bin/mcp-host ${manifest}";
        User = "hermes";
        Group = "users";
        Restart = "always";
        RestartSec = 2;
        # Background weight: it must never compete with the interactive agent
        # at equal priority, and it should not sit in the 2-thread hermes cpuset.
        Slice = "background.slice";
        TimeoutStopSec = 20;
        KillMode = "control-group";
      };
    };

    # Hermes side. `settings` is copied verbatim into config.yaml and
    # deep-merged, the same escape hatch already used for `transport: sse`.
    services.hermes-agent.mcpServers = lib.mkIf cfg.takeover {
      mcp-host = {
        url = "http://127.0.0.1:${toString cfg.port}/mcp";
        timeout = 300;
      };
    };

    services.hermes-agent.settings = lib.mkIf cfg.takeover
      (lib.genAttrs (builtins.attrNames hosted)
        (n: { mcp_servers.${n}.enabled = false; }));
  };
}
