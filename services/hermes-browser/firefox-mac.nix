# services/hermes-browser/firefox-mac.nix
# Serveur MCP "firefox-mac" : le navigateur du MAC de marc, piloté par Hermes
# (qui tourne sur tower). Même serveur officiel Mozilla que services/firefox-mcp
# (mozilla/firefox-devtools-mcp 0.10.4), mais exécuté LÀ-BAS via ssh : le MCP
# parle stdio, le wrapper exec simplement `ssh mac ...`, et geckodriver +
# Selenium WebDriver BiDi lancent le LibreWolf du Mac localement (le driver ne
# peut pas lancer un navigateur d'une autre machine, le process vit donc côté
# Mac).
#
# == Depuis le 07/11/2026 : instance agent séparée en --connectExisting ==
# Le serveur ne lance PLUS de navigateur : il s'attache à l'instance Firefox
# « firefox-hermes » du Mac, démarrée par launchd avec --marionette (2828)
# --remote-debugging-port 9222 (module nix-darwin
# modules/home-mac/firefox-hermes). Pourquoi séparée : mesuré le 07/11/2026,
# un Firefox --marionette annonce navigator.webdriver=true en permanence
# (anti-bots : Turnstile ne se rend même pas ; le pref dom.webdriver.enabled
# n'existe plus depuis FF88) — donc le navigateur QUOTIDIEN de marc ne porte
# plus jamais marionette. L'instance agent a son propre profil
# (~/.firefox-hermes-agent, vierge : les logins se font un par un quand un
# site en a besoin) et survit aux sessions Hermes (musique YouTube = côté
# quotidien, indépendant).
# Vérifié sur un Firefox jetable : navigate/list_pages OK, deux connexions
# successives OK, Firefox toujours vivant après la sortie du serveur.
# Marionette n'accepte qu'UN client à la fois : deux sessions Hermes
# simultanées se gênent. Les notes LibreWolf ci-dessous sont historiques.
#
# == Côté Mac (impératif, PAS géré par ce flake) ==
# hosts/macos a le module homebrew désactivé, ces deux outils vivent hors nix :
#   brew install geckodriver                              # 0.37.1 (25/10/2026)
#   npm install -g @mozilla/firefox-devtools-mcp@0.10.4   # node brew v25.2.1
# Mise à jour : `brew upgrade geckodriver` + `npm install -g
# @mozilla/firefox-devtools-mcp@latest` (mettre à jour la version ci-dessus).
#
# == Décisions vérifiées le 25/10/2026 ==
# - geckodriver accepte /Applications/LibreWolf.app/Contents/MacOS/librewolf :
#   version 145.0.1 lue depuis le bundle, pas de piège application.ini comme
#   sur le binaire unwrapped nix de tower. Session W3C créée puis fermée OK.
# - --firefoxArg -no-remote : le LibreWolf PERSO de marc tourne en permanence
#   sur le Mac (profil ~/Library/Application Support/librewolf). Sans
#   -no-remote, une 2e invocation du même binaire risque d'être absorbée par
#   l'instance existante. Avec, l'instance d'automation démarre à côté sur son
#   profil dédié et le perso n'est jamais touché (vérifié : navigate_page +
#   take_snapshot, LibreWolf perso intact, zéro process résiduel après sortie).
# - PAS de --headless : le but est que marc VOIE la fenêtre sur son écran.
#   Pour la discrétion, ajouter --headless à remoteCmd.
# - Profil d'automation dédié et persistant :
#   /Users/marc/.firefox-mcp-mac/profile/firefox_devtools_mcp_profile
#   (sous-dossier créé par le serveur au 1er lancement). Login manuel une fois
#   par site : ouvrir CE profil dans un LibreWolf visible (fermer l'instance
#   d'automation d'abord, un seul process par profil), se connecter, fermer :
#     /Applications/LibreWolf.app/Contents/MacOS/librewolf --no-remote \
#       --profile /Users/marc/.firefox-mcp-mac/profile/firefox_devtools_mcp_profile
#   Les cookies restent ensuite disponibles pour l'automation.
#
# == Transport ==
# stdio à travers ssh, alias de l'utilisateur hermes (cf ~/.ssh/config) :
# maclan d'abord (LAN direct, rapide), repli mac (tunnel inverse via rack,
# marche depuis n'importe quel réseau). BatchMode strict : clé id_ed25519
# seulement, aucune interaction possible. Le repli ne se déclenche que si la
# connexion à maclan échoue, aucune lecture de stdin n'a lieu avant connexion.
{
  pkgs,
  lib,
  ...
}: let
  remoteCmd = lib.concatStringsSep " " [
    "export PATH=/opt/homebrew/bin:$PATH;"
    "exec /opt/homebrew/bin/firefox-devtools-mcp"
    "--connectExisting"
    "--marionettePort 2828"
  ];

  ssh = "${pkgs.openssh}/bin/ssh";

  wrapper = pkgs.writeShellScript "firefox-mac-mcp" ''
    HOST_CMD=${lib.escapeShellArg remoteCmd}
    SSH=${ssh}
    if "$SSH" -T -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=6 maclan "$HOST_CMD"; then
      exit 0
    fi
    exec "$SSH" -T -o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=6 mac "$HOST_CMD"
  '';
in {
  services.hermes-agent.mcpServers.firefox-mac = {
    command = "${wrapper}";
    # L'instance agent (launchd, côté Mac) peut être froide au 1er appel ;
    # le défaut de 120s est trop court pour le pire cas.
    timeout = 300;
  };
}
