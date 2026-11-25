# services/qbittorrent-mcp/default.nix
# qBittorrent MCP server (arr-mcps/qbittorrent-mcp): the whole WebUI API v2
# (torrents, transfers, categories/tags, RSS, search) in 10 grouped tools,
# one `operation` per endpoint.
#
# Auth: NO credential. The server hits http://127.0.0.1:8084 and
# qBittorrent exempts local requests from login (AuthSubnetWhitelistEnabled
# + 127.0.0.1/32 in services/qbittorrent). Same model as the newt tunnel, which
# also reaches loopback. If the whitelist ever disappears: generate an
# API key (qBittorrent >= 5.2, Preferences > WebUI > API Key, format qbt_...) and
# pass it via sops in QBITTORRENT_API_KEY (never in the store).
#
# No systemd unit: stdio transport, hermes spawns the binary as a subprocess.
{pkgs, ...}: let
  python = pkgs.python312;

  # fastmcp dependencies (full extras) whose test suite does not pass
  # in the sandbox, and which are not in the 26.05 binary cache: without these
  # doCheck = false, fastmcp (so qbittorrent-mcp, and the whole toplevel with it)
  # does not build. Observed: portalocker 3.2.0 (flaky multiprocess test,
  # TimeoutError at 1.5 s), azure-core 1.38.0 (271 pytest-asyncio errors
  # "Didn't start!"), inquirer 3.4.1 (38 pexpect acceptance tests without
  # TTY), chalice 1.33.0 (blocked by inquirer). Override scoped to the python set
  # used here only.
  py = python.pkgs.overrideScope (final: prev: {
    portalocker = prev.portalocker.overridePythonAttrs (_: {doCheck = false;});
    azure-core = prev.azure-core.overridePythonAttrs (_: {doCheck = false;});
    inquirer = prev.inquirer.overridePythonAttrs (_: {doCheck = false;});
    chalice = prev.chalice.overridePythonAttrs (_: {doCheck = false;});
  });

  qbittorrent-mcp = py.buildPythonApplication {
    pname = "qbittorrent-mcp";
    version = "0.2.0";
    src = pkgs.fetchFromGitHub {
      owner = "arr-mcps";
      repo = "qbittorrent-mcp";
      rev = "32b2e5bb1d68d1158d0cae5eed91743f01e50647"; # tag v0.2.0
      hash = "sha256-Eq1V8jQkgKrVL+c3y8G6fjVYVMw7M0CmiQ3Fb6QBKBU=";
    };
    pyproject = true;
    build-system = [py.hatchling];
    dependencies = [py.fastmcp py.httpx];
    doCheck = false; # the only useful tests require a live qBittorrent
    meta = {
      description = "MCP server exposing qBittorrent's WebUI API v2";
      license = pkgs.lib.licenses.mit;
      mainProgram = "qbittorrent-mcp";
    };
  };
in {
  # On the PATH to be able to probe the server by hand (stdio).
  environment.systemPackages = [qbittorrent-mcp];

  services.hermes-agent.mcpServers.qbittorrent = {
    command = "${qbittorrent-mcp}/bin/qbittorrent-mcp";
    env.QBITTORRENT_URL = "http://127.0.0.1:8084";
    timeout = 120;
  };
}
