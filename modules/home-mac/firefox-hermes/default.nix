# Firefox du Mac pilotable par Hermes (module nix-darwin, importé par
# profiles/macos/configuration.nix).
#
# Firefox (profil quotidien de marc, session et cookies conservés) est lancé
# par launchd avec Marionette (127.0.0.1:2828) et WebDriver BiDi
# (127.0.0.1:9222). Le serveur MCP « firefox-mac » de tower
# (services/firefox-mac-mcp) s'y attache en --connectExisting à travers ssh :
# l'instance survit aux sessions Hermes, la musique continue après la fin
# d'une conversation. LibreWolf reste le navigateur des sites sensibles.
#
# - Firefox reste l'app impérative de /Applications (auto-update Mozilla,
#   binaire universel arm64) ; seul le lancement est déclaratif.
# - Si Firefox tourne déjà SANS ces flags (lancé depuis le Dock, réouverture
#   des fenêtres à la connexion), le wrapper attend qu'il soit quitté puis
#   prend le relais : jamais deux instances sur le même profil.
# - KeepAlive : un Cmd+Q relance Firefox (avec les flags) après ~30 s.
#   Arrêt réel : launchctl bootout gui/$(id -u)/org.nixos.firefox-hermes
# - Effets visibles du mode piloté : icône robot et barre d'adresse rayée,
#   navigator.webdriver=true (certains anti-bots sont plus méfiants).
# - Sécurité : ports en loopback seulement, mais sans authentification : tout
#   process local du Mac peut piloter ce Firefox. Accepté par marc.
{pkgs, ...}: let
  firefox = "/Applications/Firefox.app/Contents/MacOS/firefox";
  wrapper = pkgs.writeShellScript "firefox-hermes" ''
    while /usr/bin/pgrep -f '^${firefox}( |$)' >/dev/null; do
      sleep 15
    done
    exec ${firefox} --marionette --remote-debugging-port 9222
  '';
in {
  launchd.user.agents.firefox-hermes = {
    serviceConfig = {
      ProgramArguments = ["${wrapper}"];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      ProcessType = "Interactive";
      StandardOutPath = "/tmp/firefox-hermes.log";
      StandardErrorPath = "/tmp/firefox-hermes.err";
    };
  };
}
