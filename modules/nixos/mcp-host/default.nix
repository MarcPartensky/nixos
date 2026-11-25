# modules/nixos/mcp-host/default.nix
# A single MCP process for all the home servers.
#
# Measured problem: each Hermes session launches one process per server (32 per
# session, 133 measured on tower), each with its own Python interpreter and its
# copy of the SDK. Measured cost per process: 54 MB of RSS and 910 ms of startup,
# of which 33 ms for the interpreter and 1005 ms for importing the SDK. Idle tools
# end up in swap and weigh 4 GB.
#
# This module launches a single daemon that mounts the existing servers without
# modifying them (import shim in mcp/main.py) and serves everything on a single
# loopback URL, over streamable HTTP. Measured with 8 real servers: 90 tools, 85 MB
# of RSS, 2 processes.
#
# The server code stays in the repo, but their list is frozen here:
# modifying it requires a switch. NEW tools go into the modules
# folder (mcp/modules of the repo, deployed by `just mcp-deploy`), which is re-read
# without restarting.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.mcp-host;

  pythonEnv = pkgs.python3.withPackages (ps: [ps.fastmcp] ++ cfg.extraPythonPackages);

  # List name -> .py file path, consumed by mcp/main.py.
  manifest = pkgs.writeText "mcp-host-servers.json" (builtins.toJSON cfg.servers);
  # Hermes stdio servers that this daemon takes charge of (Rust binaries,
  # python packages, npx). The LIST of names is an option (stdioServers, in
  # the profile) and not a derivation of `config.services.hermes-agent.
  # mcpServers`: this module itself defines entries in that option
  # (enabled = false), so deriving the names from the result forms a loop
  # (`hostedStdio = f (attrNames (g hostedStdio))`) and the eval dies with
  # "infinite recursion encountered" (observed on 21/11/2026).
  # We therefore read the VALUES from a constant list of names.
  hostedStdio = lib.filterAttrs
    (n: v: (v.command or null) != null)
    (lib.getAttrs cfg.stdioServers config.services.hermes-agent.mcpServers);

  stdioManifest = pkgs.writeText "mcp-host-stdio.json" (builtins.toJSON
    (lib.mapAttrs
      (n: v: {
        command = v.command;
        args = v.args or [];
        env = v.env or {};
      })
      hostedStdio));
in {
  options.services.mcp-host = {
    enable = lib.mkEnableOption "single MCP server hosting the home servers";

    servers = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      example = lib.literalExpression ''{shorturl = ../../services/shorturl-mcp/server.py;}'';
      description = ''
        Existing servers to mount, in the form name = path of the
        python file. Each file must expose a FastMCP instance in a
        variable `mcp`, `app` or `server`. A file that fails is ignored and
        logged, the others keep serving.
      '';
    };

    modulesDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/mcp/modules";
      description = ''
        Folder re-read on each request for the hot-added tools
        (decorator `from fastmcp.tools import tool`). It is the only
        mutable part of the system, fed by `just mcp-deploy`.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4780;
      description = "Loopback port of the daemon. Do not open on the firewall: only Hermes reaches it.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
      description = ''
        Daemon user. Keeping `hermes` reproduces the current rights of the
        MCP servers (launched by the agent); switch to `root` only if a
        tool needs privileges that hermes does not have.
      '';
    };

    extraPythonPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Additional libraries for the new modules (httpx, etc.).";
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Daemon environment variables. Indispensable when mounted servers
        read their configuration at import (API URLs, secret file
        paths): they then share a single environment, so
        you need the union of what each module received over stdio.
      '';
    };

    hermesGateway = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Switches Hermes sessions to the daemon's single URL instead of launching
        one process per server. Only enable after removing the stdio
        mcpServers entries for the servers concerned: otherwise the tools are
        exposed twice, under two different namespaces.
      '';
    };

    hostHermesStdio = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Takes charge of ALL the stdio servers of `services.hermes-agent.
        mcpServers` (Rust binaries, python packages, npx) by proxying them
        from this daemon, and sets `enabled = false` on their Hermes entries.

        Measurement of 21/11/2026 on tower: 26 stdio servers x 5 sessions = 103
        processes, 322 threads, 10.6 GB of RSS, for the same list of tools
        served five times. A single instance here brings that back to one set of
        processes, launched on demand and shared by all sessions.

        The servers are mounted with `namespace = <name>`, so the tools
        are called `<name>_<tool>` (gitea_create_issue). Without namespace, 57
        tools of the same name overwrite each other across servers (459 tools instead of
        516, measured): do not remove the namespace without recounting.
      '';
    };

    stdioServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["gitea" "shlink" "stalwart"];
      description = ''
        Names of the stdio servers of `services.hermes-agent.mcpServers` taken
        charge of by this daemon. The list is explicit (not derived): see the
        comment on `hostedStdio` about the eval loop. Adding a server
        here is therefore a second declaration, to be done at the same time as
        the Hermes entry.

        To leave aside: vaultwarden (client_id missing) and codeberg
        (python-dotenv missing from its venv), broken at the source: proxying
        them would only move the failure.
      '';
    };

    purgedServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["beeper"];
      description = ''
        Entries permanently removed from config.yaml on each activation
        (not merely turned off): integrations abandoned for good.
      '';
    };

    staleStdioServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["roku" "zitadel"];
      description = ''
        Entries present in config.yaml whose Nix module has been commented out.
        The deep merge of activation keeps them, so each session still
        launches them: they are turned off (`enabled = false`) without their
        configuration being erased. An entry listed here must be either
        redeclared, or removed from the file by hand.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The modules folder must exist and belong to the daemon's
    # user, otherwise the FileSystemProvider silently ignores its files.
    systemd.tmpfiles.rules = [
      "d ${cfg.modulesDir} 0755 ${cfg.user} ${cfg.user} -"
    ];

    # Hermes switch: a single URL entry instead of one process per server.
    # The tool names become mcp__hermes-tools__<tool>, so any skill
    # or cron that cites a full name must be updated.
    #
    # The URL points to /sse, NOT /mcp: mcp/main.py runs in SSE transport (the
    # Hermes runtime of tower does not have mcp.client.streamable_http), and this
    # transport mounts the stream on /sse and the messages on /messages. A URL
    # /mcp answers 404 and hermes marks the server as connection failure
    # (observed on 15/11/2026: 30+ home tools unreachable).
    # The `transport: sse` key is NOT settable here: the mcpServers option
    # is a typed submodule without a transport key. It is declared in
    # services/hermes (settings.mcp_servers.hermes-tools.transport).
    services.hermes-agent.mcpServers = lib.mkIf cfg.hermesGateway {
      hermes-tools.url = "http://127.0.0.1:${toString cfg.port}/sse";
    };

    # Turning off the servers taken charge of (and the ghost entries), written
    # into config.yaml by activation, AFTER the Nix merge.
    #
    # Why not `services.hermes-agent.mcpServers.<n>.enabled = false`:
    # this module already reads that option to build the manifest, and defining
    # an entry in an option that we read forces the merge of ALL the
    # definitions to know the names, hence `hostedStdio = f (attrNames (g
    # hostedStdio))`: "infinite recursion encountered" (observed on
    # 21/11/2026, twice).
    # Why not `settings.mcp_servers.<n>.enabled`: the conversion
    # mcpServersToConfig rewrites all of `mcp_servers` at normal priority and
    # wins, the entries stayed `enabled: true` (observed too).
    # What remains is activation: it runs before the units start, the list
    # comes from Nix, and the result is the same on each switch.
    system.activationScripts."hermes-mcp-host-takeover" =
      lib.mkIf cfg.hostHermesStdio
        (lib.stringAfter [ "hermes-agent-setup" ] ''
          ${pkgs.python3.withPackages (ps: [ps.pyyaml])}/bin/python ${./disable-stdio.py} \
            "${config.services.hermes-agent.stateDir}/.hermes/config.yaml" \
            ${lib.escapeShellArg (builtins.toJSON (lib.unique (builtins.attrNames hostedStdio ++ cfg.staleStdioServers)))} \
            ${lib.escapeShellArg (builtins.toJSON cfg.purgedServers)}
        '');

    systemd.services.mcp-host = {
      description = "Single MCP server (home servers + hot modules)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      # nixpkgs derives `environment.PATH` from this option and sets it with
      # mkForce: two mkForce on the same key = eval conflict, which blocked
      # EVERY switch. We empty the list and keep our explicit PATH
      # below (same content, plus the profile's tools).
      path = lib.mkForce [];

      environment = {
        MCP_HOST_MANIFEST = "${manifest}";
        MCP_HOST_MODULES = cfg.modulesDir;
        MCP_HOST_PORT = toString cfg.port;
        MCP_HOST_ADDR = "127.0.0.1";
        # Manifest of the proxied stdio servers (gitea-mcp, npx, Rust
        # binaries...). The children inherit this environment: without HOME or
        # PATH, gitea-mcp and npx do not launch. `mkForce` is mandatory:
        # the systemd module of nixpkgs already sets a PATH (coreutils, findutils,
        # gnugrep, systemd) and two types.str definitions come into
        # conflict. The system profile is put back at the front to recover those
        # tools, plus the default PATH of nixpkgs as fallback.
        MCP_HOST_STDIO = "${stdioManifest}";
        HOME = "/var/lib/hermes";
        PATH = lib.mkForce ("/run/current-system/sw/bin:/etc/profiles/per-user/hermes/bin:/var/lib/hermes/.local/bin:"
          + lib.makeBinPath [pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.systemd]);
      } // cfg.env;

      serviceConfig = {
        ExecStart = "${pythonEnv}/bin/python ${../../../mcp/main.py}";
        User = cfg.user;
        Group = cfg.user;
        Restart = "always";
        RestartSec = 2;
        # A tool that blocks must not freeze the loop: the SDK runs the
        # synchronous tools in a threadpool, this timeout bounds the worst case.
        TimeoutStopSec = 10;
        # Hardening without breaking the file accesses that the tools need
        # (sops secrets in /run/secrets, local state of some tools).
        NoNewPrivileges = false;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
      };
    };
  };
}
