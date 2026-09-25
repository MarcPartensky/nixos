# services/firefox-mcp/default.nix
# Serveur MCP Firefox DevTools (mozilla/firefox-devtools-mcp) : officiel Mozilla,
# automatise un LibreWolf réel via WebDriver BiDi (geckodriver + Selenium) —
# navigation, snapshots d'accessibilité, clics/saisie, réseau, téléchargements,
# screenshots, exécution JS. PAS un navigateur patché comme Playwright.
# Actif (releases régulières, dernière v0.10.4 le 2026-09-22), dual
# MIT/Apache-2.0, documenté dans firefox-source-docs.mozilla.org.
#
# Transport stdio (hermes spawn le binaire en subprocess), comme amazon-mcp.
# Tools préfixés mcp_firefox_* (navigate_page, take_snapshot, click_by_uid,
# fill_by_uid, list_network_requests, screenshot_page, list_console_messages...).
# Preset par défaut "basic" (inclut déjà evaluate_script). Pour plus de outils :
# ajouter "--tool-preset" "developer" (debug/réseau/profiler) ou "mozilla"
# (contexte privilégié) aux args du wrapper ci-dessous.
#
# Navigateur : LibreWolf (pkgs.librewolf-unwrapped), même moteur Gecko.
# Geckodriver n'accepte que le VRAI binaire applicatif : son contrôle de
# « Firefox executable » se fait via l'application.ini situé DANS le dossier du
# binaire (vérifié : ${pkgs.librewolf-unwrapped}/lib/librewolf/librewolf passe,
# Name=LibreWolf dans application.ini ne le dérange pas), alors que le shim
# bin/librewolf (qui n'a pas d'application.ini à côté) est refusé avec
# « binary is not a Firefox executable » — pareil pour pkgs.librewolf/bin/librewolf,
# un script bash nix.
#
# Profil : dédié et persistant sous /var/lib/hermes/firefox-mcp/profile (JAMAIS
# le profil personnel de marc — recommandation sécurité upstream, README
# "Security"). Le serveur crée lui-même le sous-dossier
# firefox_devtools_mcp_profile/ au premier lancement (src/firefox/profile.ts),
# pas besoin de le pré-créer : juste le parent, via tmpfiles ci-dessous.
#
# Headless par défaut : le service hermes n'a pas de session graphique attachée
# (ProtectSystem=strict, pas de DISPLAY/WAYLAND_DISPLAY). Pour du debug visuel,
# lancer le wrapper à la main sans --headless depuis une session graphique de
# marc (wayvnc) — même principe que amazon-mcp-login mais pas câblé en script
# dédié ici faute de besoin (pas de login/2FA à faire pour naviguer).
#
# geckodriver : le paquet npm "geckodriver" (dépendance de firefox-devtools-mcp)
# télécharge un binaire non-nix au premier usage UNIQUEMENT s'il ne trouve aucun
# geckodriver sur le PATH (voir GECKODRIVER_AUTO_INSTALL dans son README — pas
# activé ici, donc pas de tentative réseau au build). On met pkgs.geckodriver
# (vrai binaire nix) en tête de PATH pour que findGeckodriverInPath()
# (src/firefox/core.ts) le trouve en premier et court-circuite tout téléchargement.
{
  pkgs,
  lib,
  inputs,
  ...
}: let
  stateDir = "/var/lib/hermes/firefox-mcp";
  browser = pkgs.librewolf-unwrapped;
  nodejs = pkgs.nodejs_22; # LTS ; le projet exige seulement node >=20.19.0

  firefox-devtools-mcp = pkgs.buildNpmPackage {
    pname = "firefox-devtools-mcp";
    version = "0.10.4";
    src = inputs.firefox-devtools-mcp;
    inherit nodejs;

    npmDepsHash = "sha256-+pJwxFmgnFWUCvt5wWWFXvyO5oUiTamgaEkQdk0lZoo=";

    meta = {
      description = "Official Mozilla MCP server for Firefox DevTools automation (WebDriver BiDi)";
      homepage = "https://github.com/mozilla/firefox-devtools-mcp";
      license = [lib.licenses.mit lib.licenses.asl20];
      mainProgram = "firefox-devtools-mcp";
    };
  };

  # PIÈGE vérifié en vrai : geckodriver lit la version de Firefox depuis
  # `application.ini` à côté du binaire (mozversion), sinon en scannant le
  # binaire ; sinon il refuse la session avec
  # « <chemin> is not a Firefox executable » (src/capabilities.rs, version()).
  # Ni ${pkgs.librewolf}/bin/librewolf (script bash de wrapFirefox) ni
  # librewolf-unwrapped/bin/librewolf (shim ELF de 16 Ko, pas d'application.ini
  # dans bin/) ne passent : le VRAI binaire d'application est
  # lib/librewolf/librewolf, dont le dossier contient bien application.ini.
  wrapper = pkgs.writeShellScript "firefox-mcp-hermes" ''
    export PATH="${pkgs.geckodriver}/bin:$PATH"
    exec ${lib.getExe firefox-devtools-mcp} \
      --firefox-path "${browser}/lib/librewolf/librewolf" \
      --profile-path "${stateDir}/profile" \
      --headless \
      "$@"
  '';

  # Profil réellement utilisé par le serveur : <profile-path>/firefox_devtools_mcp_profile
  # (resolveProfilePath(), src/firefox/profile.ts — il ajoute toujours ce sous-dossier
  # pour ne jamais tomber sur un vrai profil perso). C'est CE dossier qu'il faut
  # ouvrir pour le login manuel, sinon les cookies ne sont pas ceux que le
  # serveur headless relit ensuite.
  profileDir = "${stateDir}/profile/firefox_devtools_mcp_profile";

  # Login manuel : le serveur tourne en headless, donc l'humain doit ouvrir le
  # même profil dans un navigateur VISIBLE une fois, se connecter (Proton,
  # webmail sans Bridge), puis fermer. À lancer depuis la session graphique de
  # marc (niri), sans sudo — le profil est partagé par ACL (voir tmpfiles).
  loginHelper = pkgs.writeShellApplication {
    name = "firefox-mcp-login";
    runtimeInputs = [pkgs.librewolf pkgs.procps pkgs.gnugrep];
    text = ''
      url="''${1:-https://mail.proton.me/}"
      # Firefox ne crée PAS le dossier de profil : sans lui il meurt sur
      # « Could not find profile folder. » (vérifié). Le serveur le crée au
      # premier lancement, ce mkdir couvre le cas où on se connecte avant.
      mkdir -p "${profileDir}"
      # Firefox refuse deux instances sur un même profil : on prévient avant.
      if pgrep -f -- "--profile ${profileDir}" >/dev/null; then
        echo "Un navigateur MCP tourne déjà sur ce profil (session hermes active)." >&2
        echo "Arrête-la d'abord : le profil ne peut pas être ouvert deux fois." >&2
        exit 1
      fi
      echo "Connecte-toi à $url dans la fenêtre qui s'ouvre, puis ferme-la."
      exec librewolf --no-remote --profile "${profileDir}" "$url"
    '';
  };
in {
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 hermes hermes -"
    # Profil partagé : hermes (serveur MCP headless) <-> marc (login manuel).
    # "a" ne rejoue qu'au BOOT ; après le premier switch :
    #   sudo systemd-tmpfiles --create
    "a /var/lib/hermes - - - - u:marc:--x,m::rwx"
    "d ${stateDir}/profile 0750 hermes hermes -"
    "a ${stateDir} - - - - u:marc:rwx,d:u:marc:rwx,d:u:hermes:rwx,m::rwx,d:m::rwx"
    "a ${stateDir}/profile - - - - u:marc:rwx,d:u:marc:rwx,d:u:hermes:rwx,m::rwx,d:m::rwx"
    "d ${profileDir} 0750 hermes hermes -"
    "a ${profileDir} - - - - u:marc:rwx,d:u:marc:rwx,d:u:hermes:rwx,m::rwx,d:m::rwx"
  ];

  environment.systemPackages = [loginHelper];

  services.hermes-agent.mcpServers.firefox = {
    command = "${wrapper}";
    timeout = 180; # certaines pages/SPA peuvent dépasser le défaut de 120s
  };
}
