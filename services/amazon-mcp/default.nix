# services/amazon-mcp/default.nix
# Amazon MCP server (duaragha/amazon-shopping-mcp): search, product pages,
# reviews, cart, order, returns -- via Playwright/Chromium (nix binaries).
#
# stdio transport: hermes spawns the binary as a subprocess
# (services.hermes-agent.mcpServers), so NO dedicated systemd unit:
# upstream only speaks stdio, an HTTP proxy would only add a hop.
# The tools appear prefixed mcp_amazon_* (amazon_search, amazon_add_to_cart...).
#
# Amazon session: persistent chromium profile in
# /var/lib/hermes/amazon-mcp/user-data (inside the hermes stateDir: ProtectSystem=strict
# makes everything else read-only for the service's subprocesses).
# Shared with marc via ACL for the login.
#
# LOGIN (human, once, to redo when the session expires):
#   amazon-mcp-login        # from a marc graphical session (wayvnc)
# Opens a VISIBLE chromium on amazon.com: type password + 2FA, then
# Enter in the terminal -> the session is persisted for the hermes service.
#
# Debug:
#   journalctl -u hermes-agent -f          # the mcp_amazon_* tools at startup
#   AMAZON_HEADLESS=0 amazon-mcp-login     # see what the browser sees
#
# Warning: automated purchase of a logged-in session, contrary to Amazon's ToS
# (risk of flag/restriction of the account in case of intensive use).
# amazon_place_order requires confirm=true (preview by default): nothing is
# bought without explicit confirmation in the conversation.
{pkgs, ...}: let
  python = pkgs.python312;
  py = python.pkgs;

  amazon-mcp = py.buildPythonApplication {
    pname = "amazon-mcp";
    version = "0.1.0-unstable-2026-06-02";
    src = pkgs.fetchFromGitHub {
      owner = "duaragha";
      repo = "amazon-shopping-mcp";
      rev = "7ed30d8fb1415b633a6018baa9f7bf6fc71d0043";
      hash = "sha256-XvIfNcxfE5JAIZJqs+gBi6Rew0F72oiotBpyeUxTd04=";
    };
    pyproject = true;
    build-system = [py.hatchling];
    # playwright from nixpkgs: driver patched to playwright-driver (cli.js),
    # the browsers come from PLAYWRIGHT_BROWSERS_PATH (env below)
    dependencies = [py.mcp py.playwright];
    doCheck = false; # no upstream tests
    meta = {
      description = "MCP server: search, compare and buy on Amazon via Playwright";
      license = pkgs.lib.licenses.mit;
      mainProgram = "amazon-mcp";
    };
  };

  # Manual login: opens a visible chromium on the SAME persistent profile as
  # the MCP server -> the session cookies are reused by hermes.
  login-py = pkgs.writeText "amazon-mcp-login.py" ''
    import os
    from playwright.sync_api import sync_playwright

    data_dir = os.environ.get("AMAZON_USER_DATA_DIR", "/var/lib/hermes/amazon-mcp/user-data")
    domain = os.environ.get("AMAZON_DOMAIN", "com")

    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            data_dir,
            headless=False,
            args=["--disable-blink-features=AutomationControlled"],
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto(f"https://www.amazon.{domain}/")
        input("Log in in the chromium window (password + 2FA), "
              "then press Enter here to save the session... ")
        ctx.close()
    print("Session persisted in " + data_dir)
  '';

  amazon-mcp-login = pkgs.writeShellApplication {
    name = "amazon-mcp-login";
    runtimeInputs = [(python.withPackages (ps: [ps.playwright]))];
    text = ''
      export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
      exec python3 ${login-py}
    '';
  };
in {
  # login helper available in marc's graphical session
  environment.systemPackages = [amazon-mcp-login];

  # Profile shared hermes (MCP service) <-> marc (login).
  # /var/lib/hermes is 2770 hermes:hermes: marc needs a traversal --x.
  # NB: tmpfiles "a"/"d" are only replayed at BOOT; after the first switch:
  #   sudo systemd-tmpfiles --create
  systemd.tmpfiles.rules = [
    "a /var/lib/hermes - - - - u:marc:--x,m::rwx"
    "d /var/lib/hermes/amazon-mcp 0750 hermes hermes - -"
    "a /var/lib/hermes/amazon-mcp - - - - u:marc:rwx,d:u:marc:rwx,d:u:hermes:rwx,m::rwx,d:m::rwx"
  ];

  # Hermes spawns the server over stdio; its subprocess env is filtered ->
  # pass everything explicitly via env here.
  services.hermes-agent.mcpServers.amazon = {
    command = "${amazon-mcp}/bin/amazon-mcp";
    env = {
      PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
      AMAZON_USER_DATA_DIR = "/var/lib/hermes/amazon-mcp/user-data";
      # storefront .com (NYC); switch to "fr" for amazon.fr
      AMAZON_DOMAIN = "com";
      AMAZON_HEADLESS = "1";
    };
    timeout = 300; # scraping product pages in parallel can take a while
    sampling.enabled = false; # unaudited community server
  };
}
