# services/qbittorrent-mcp/default.nix
# Serveur MCP qBittorrent (arr-mcps/qbittorrent-mcp) : toute l'API WebUI v2
# (torrents, transferts, catégories/tags, RSS, recherche) en 10 outils groupés,
# un `operation` par endpoint.
#
# Auth : AUCUNE credential. Le serveur tape http://127.0.0.1:8084 et
# qBittorrent dispense de login les requêtes locales (AuthSubnetWhitelistEnabled
# + 127.0.0.1/32 dans services/qbittorrent). Même modèle que le tunnel newt, qui
# joint lui aussi la loopback. Si la whitelist disparaît un jour : générer une
# clé API (qBittorrent >= 5.2, Preferences > WebUI > API Key, format qbt_...) et
# la passer par sops en QBITTORRENT_API_KEY (jamais dans le store).
#
# Pas d'unité systemd : transport stdio, hermes spawn le binaire en subprocess.
{pkgs, ...}: let
  python = pkgs.python312;

  # Dépendances de fastmcp (extras complets) dont la suite de tests ne passe
  # pas en sandbox, et qui ne sont pas dans le cache binaire 26.05 : sans ces
  # doCheck = false, fastmcp (donc qbittorrent-mcp, et tout le toplevel avec)
  # ne se construit pas. Constaté : portalocker 3.2.0 (test multiprocess flaky,
  # TimeoutError à 1.5 s), azure-core 1.38.0 (271 erreurs pytest-asyncio
  # « Didn't start! »), inquirer 3.4.1 (38 tests d'acceptation pexpect sans
  # TTY), chalice 1.33.0 (bloqué par inquirer). Override scopé au set python
  # utilisé ici uniquement.
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
    doCheck = false; # les seuls tests utiles exigent un qBittorrent live
    meta = {
      description = "MCP server exposing qBittorrent's WebUI API v2";
      license = pkgs.lib.licenses.mit;
      mainProgram = "qbittorrent-mcp";
    };
  };
in {
  # Sur le PATH pour pouvoir sonder le serveur à la main (stdio).
  environment.systemPackages = [qbittorrent-mcp];

  services.hermes-agent.mcpServers.qbittorrent = {
    command = "${qbittorrent-mcp}/bin/qbittorrent-mcp";
    env.QBITTORRENT_URL = "http://127.0.0.1:8084";
    timeout = 120;
  };
}
