# services/amazon-mcp/default.nix
# Serveur MCP Amazon (duaragha/amazon-shopping-mcp) : recherche, fiches produits,
# avis, panier, commande, retours — via Playwright/Chromium (binaires nix).
#
# Transport stdio : hermes spawn le binaire en subprocess
# (services.hermes-agent.mcpServers), donc PAS d'unité systemd dédiée :
# upstream ne parle que stdio, un proxy HTTP n'ajouterait qu'un hop.
# Les tools apparaissent préfixés mcp_amazon_* (amazon_search, amazon_add_to_cart...).
#
# Session Amazon : profil chromium persistant dans
# /var/lib/hermes/amazon-mcp/user-data (dans le stateDir hermes : ProtectSystem=strict
# rend tout le reste en lecture seule pour les subprocess du service).
# Partagé avec marc par ACL pour le login.
#
# LOGIN (humain, une fois, à refaire quand la session expire) :
#   amazon-mcp-login        # depuis une session graphique de marc (wayvnc)
# Ouvre un chromium VISIBLE sur amazon.com : taper mot de passe + 2FA, puis
# Entrée dans le terminal -> la session est persistée pour le service hermes.
#
# Debug :
#   journalctl -u hermes-agent -f          # les tools mcp_amazon_* au démarrage
#   AMAZON_HEADLESS=0 amazon-mcp-login     # voir ce que le navigateur voit
#
# Attention : l'achat automatise une session loguée, contraire aux CGU Amazon
# (risque de flag/restriction du compte en cas d'usage intensif).
# amazon_place_order exige confirm=true (preview par défaut) : rien n'est
# acheté sans confirmation explicite dans la conversation.
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
    # playwright de nixpkgs : driver patché vers playwright-driver (cli.js),
    # les navigateurs viennent de PLAYWRIGHT_BROWSERS_PATH (env ci-dessous)
    dependencies = [py.mcp py.playwright];
    doCheck = false; # pas de tests upstream
    meta = {
      description = "MCP server: search, compare and buy on Amazon via Playwright";
      license = pkgs.lib.licenses.mit;
      mainProgram = "amazon-mcp";
    };
  };

  # Login manuel : ouvre un chromium visible sur le MÊME profil persistant que
  # le serveur MCP -> les cookies de session sont réutilisés par hermes.
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
        input("Connecte-toi dans la fenêtre chromium (mot de passe + 2FA), "
              "puis appuie sur Entrée ici pour sauver la session... ")
        ctx.close()
    print("Session persistée dans " + data_dir)
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
  # helper de login dispo dans la session graphique de marc
  environment.systemPackages = [amazon-mcp-login];

  # Profil partagé hermes (service MCP) <-> marc (login).
  # /var/lib/hermes est en 2770 hermes:hermes : marc a besoin d'un --x de traversée.
  # NB : tmpfiles "a"/"d" ne sont rejoués qu'au BOOT ; après le premier switch :
  #   sudo systemd-tmpfiles --create
  systemd.tmpfiles.rules = [
    "a /var/lib/hermes - - - - u:marc:--x,m::rwx"
    "d /var/lib/hermes/amazon-mcp 0750 hermes hermes - -"
    "a /var/lib/hermes/amazon-mcp - - - - u:marc:rwx,d:u:marc:rwx,d:u:hermes:rwx,m::rwx,d:m::rwx"
  ];

  # Hermes spawn le serveur en stdio ; son env subprocess est filtré ->
  # tout passer explicitement via env ici.
  services.hermes-agent.mcpServers.amazon = {
    command = "${amazon-mcp}/bin/amazon-mcp";
    env = {
      PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
      AMAZON_USER_DATA_DIR = "/var/lib/hermes/amazon-mcp/user-data";
      # storefront .com (NYC) ; passer à "fr" pour amazon.fr
      AMAZON_DOMAIN = "com";
      AMAZON_HEADLESS = "1";
    };
    timeout = 300; # le scraping de fiches parallèles peut être long
    sampling.enabled = false; # serveur communautaire non audité
  };
}
