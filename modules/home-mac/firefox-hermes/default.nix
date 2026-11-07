# Firefox du Mac : le quotidien de marc reste un Firefox NORMAL, et Hermes
# pilote une instance Firefox SÉPARÉE (module nix-darwin, importé par
# profiles/macos/configuration.nix).
#
# Pourquoi deux instances (mesuré le 07/11/2026) : dès que Firefox tourne
# avec --marionette, il annonce navigator.webdriver=true EN PERMANENCE (même
# sans client connecté, sonde vérifiée), et le pref dom.webdriver.enabled qui
# désactivait ça n'existe plus dans le binaire (Firefox >= 88, 0 occurrence).
# Résultat : un navigateur piloté se fait détecter par les anti-bots
# (Cloudflare Turnstile ne se rend même pas). On ne met donc JAMAIS marionette
# sur le navigateur quotidien de marc.
#
# - Quotidien : lancé par marc (Dock, réouverture à la connexion), aucun flag,
#   aucun agent launchd. Session restaurée via browser.startup.page=3 (user.js
#   du profil, posé hors de ce module).
# - Instance agent « firefox-hermes » : launchd, profil dédié
#   ~/.firefox-hermes-agent, --marionette (port 2828 via user.js) et
#   --remote-debugging-port 9222. Le serveur MCP « firefox-mac » de tower
#   (services/hermes-browser) s'y attache en --connectExisting à travers ssh ;
#   l'instance survit aux sessions Hermes. KeepAlive la relance après un Cmd+Q.
# - Profils séparés + --no-remote : les deux instances coexistent sans jamais
#   partager un profil. Le wrapper attend qu'une instance agent traîne déjà
#   pour ne pas doubler sur le même profil.
# - Arrêt réel de l'instance agent :
#   launchctl bootout gui/$(id -u)/org.nixos.firefox-hermes
# - Effets visibles sur l'instance agent uniquement : icône robot, barre
#   d'adresse rayée, navigator.webdriver=true. Le quotidien est normal.
# - Sécurité : ports en loopback seulement, mais sans authentification : tout
#   process local du Mac peut piloter l'instance agent. Accepté par marc.
{pkgs, ...}: let
  firefox = "/Applications/Firefox.app/Contents/MacOS/firefox";
  wrapper = pkgs.writeShellScript "firefox-hermes" ''
    PROFILE="$HOME/.firefox-hermes-agent"
    mkdir -p "$PROFILE"
    # Le MCP de tower s'attache en --connectExisting sur ce port.
    if ! /usr/bin/grep -q 'marionette.port' "$PROFILE/user.js" 2>/dev/null; then
      printf 'user_pref("marionette.port", 2828);\nuser_pref("browser.shell.checkDefaultBrowser", false);\n' >> "$PROFILE/user.js"
    fi
    # Une instance agent tourne déjà ? Attendre qu'elle parte (jamais deux
    # process sur le même profil).
    while /usr/bin/pgrep -f '^${firefox} .*firefox-hermes-agent' >/dev/null; do
      sleep 15
    done
    exec ${firefox} --no-remote -profile "$PROFILE" --marionette --remote-debugging-port 9222
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
