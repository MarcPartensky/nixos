# Chrome « agent » du Mac de marc : instance SÉPARÉE du Chrome quotidien,
# pilotée par Hermes depuis tower (CDP en loopback à travers ssh).
#
# Pourquoi Chrome et plus Firefox (mesuré 09/11/2026) :
# - Un Firefox lancé avec --marionette (ou attaché par geckodriver/Selenium)
#   annonce navigator.webdriver=true EN PERMANENCE, même sans client connecté,
#   et le pref dom.webdriver.enabled n'existe plus depuis FF88 : tout site
#   anti-bot (Cloudflare Turnstile...) le voit comme un robot. Aucun réglage
#   côté Firefox ne le masque.
# - Un Chrome lancé SANS --enable-automation (donc jamais par ChromeDriver) a
#   navigator.webdriver=undefined. Mesuré sur cette instance : bot.sannysoft.com
#   « WebDriver missing (passed) » + « WebDriver Advanced passed », et
#   nowsecure.nl (Cloudflare) sert son contenu sans challenge.
# - Le driver de tower (skill marc-mac-operations/scripts/mac-cdp.mjs) ne parle
#   que Runtime.evaluate / Page.navigate / Input.dispatch* : pas de
#   Runtime.enable, le tell CDP classique des outils Playwright/Puppeteer.
#
# Détails :
# - Profil dédié et persistant ~/.chrome-hermes-agent (jamais le profil
#   quotidien de marc : ~/Library/Application Support/Google/Chrome).
# - CDP sur 127.0.0.1:9222 seulement (un port CDP joignable = contrôle total du
#   navigateur). tower y accède par tunnel ssh loopback (19222 -> 9222).
# - Port 9333 = le navigateur de marc ; 9222 = l'agent. Chrome refuse de
#   démarrer si --remote-debugging-port est déjà pris, et refuse aussi ce flag
#   sur le profil par défaut : d'où --user-data-dir explicite.
# - Fenêtre VISIBLE sur l'écran de marc (pas de --headless) : il voit ce que
#   l'agent fait, et les logins/OAuth se tapent à la main dans cette fenêtre.
# - KeepAlive : un Cmd+Q sur l'instance agent la relance en 30 s.
#   Arrêt réel : launchctl bootout gui/$(id -u)/org.nixos.chrome-hermes
#
# EXTENSIONS (miroir du LibreWolf de marc, mesuré 09/11/2026) :
# - Chrome 157 IGNORE --load-extension (vérifié : zéro extension chargée, même
#   avec --disable-features=DisableLoadExtensionCommandLineSwitch).
# - Les .xpi de LibreWolf ne se chargent pas non plus (Firefox/WebExtension,
#   manifest v2, API browser.*). Seul uBlock Origin n'existe plus en MV2 sur
#   Chrome : on prend uBlock Origin Lite (MV3) et les versions Chrome Store des
#   mêmes éditeurs (Bitwarden, Dark Reader, SponsorBlock, Video Speed
#   Controller, Video DownloadHelper, Wappalyzer, Get cookies.txt, Moodle
#   Buddy).
# - Seule voie qui marche : CDP `Extensions.loadUnpacked`. Elles ne survivent
#   PAS à un redémarrage de Chrome, donc le wrapper lance Chrome, attend le
#   port de debug puis recharge les extensions à chaque démarrage (marc a donc
#   l'adblock et Bitwarden même quand Hermes ne pilote pas).
# - Installation des fichiers (CRX dézippés) :
#   `scripts/chrome-ext-install.py ~/.chrome-hermes-agent-ext <ids...>` du
#   skill marc-mac-operations. Mettre à jour = relancer ce script.
# - Bitwarden : marc se connecte UNE fois dans la fenêtre agent (mot de passe
#   tapé par lui), ensuite le driver remplit avec `autofill` (Meta+Shift+L).
{pkgs, lib, ...}: let
  chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  node = pkgs.nodejs_22;

  extLoader = pkgs.writeText "chrome-hermes-ext.mjs" ''
    // Recharge les extensions déballées dans le Chrome agent (CDP), une fois
    // que le port de debug répond. Ne JAMAIS appeler Runtime.enable ici.
    const BASE = 'http://127.0.0.1:9222';
    const DIR = process.env.HOME + '/.chrome-hermes-agent-ext';
    const IDS = [
      'ddkjiahejlhfcafbddmgiahcphecmpfh', // uBlock Origin Lite
      'nngceckbapebfimnlniiiahkandclblb', // Bitwarden
      'eimadpbcbfnmbkopoojfekhnkhdbieeh', // Dark Reader
      'mnjggcdmjocbbbhaepdhchncahnbgone', // SponsorBlock
      'nffaoalbilbmmfgbnbgppjihopabppdk', // Video Speed Controller
      'lmjnegcaeklhafolokijcfjliaokphfk', // Video DownloadHelper
      'gppongmhjkpfnbhagpmjfkannfbllamg', // Wappalyzer
      'cclelndahbckbenkjhflpdbgdldlbecc', // Get cookies.txt LOCALLY
      'nomahjpllnbcpbggnpiehiecfbjmcaeo', // Moodle Buddy
    ];
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    let version = null;
    for (let i = 0; i < 90 && !version; i++) {
      try {
        const r = await fetch(BASE + '/json/version');
        if (r.ok) version = await r.json();
      } catch { /* port pas encore ouvert */ }
      if (!version) await sleep(1000);
    }
    if (!version) { console.error('CDP 9222 injoignable : extensions non chargées'); process.exit(1); }
    const ws = new WebSocket(version.webSocketDebuggerUrl);
    await new Promise((res, rej) => {
      ws.addEventListener('open', res, { once: true });
      ws.addEventListener('error', () => rej(new Error('websocket refusé')), { once: true });
    });
    let id = 0;
    const pending = new Map();
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && pending.has(m.id)) {
        const p = pending.get(m.id);
        pending.delete(m.id);
        m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result);
      }
    });
    const send = (method, params = {}) => new Promise((resolve, reject) => {
      const i = ++id;
      pending.set(i, { resolve, reject });
      ws.send(JSON.stringify({ id: i, method, params }));
      setTimeout(() => { if (pending.has(i)) { pending.delete(i); reject(new Error('timeout ' + method)); } }, 20000);
    });
    let ok = 0;
    for (const extId of IDS) {
      try { await send('Extensions.loadUnpacked', { path: DIR + '/' + extId }); ok++; }
      catch (e) { console.error('KO ' + extId + ' : ' + e.message.slice(0, 120)); }
    }
    console.log('extensions chargées : ' + ok + '/' + IDS.length);
    ws.close();
    // Chaque chargement = une « installation » : les extensions ouvrent leur
    // page d'accueil. On referme ces onglets pour laisser la fenêtre propre.
    const ONBOARDING = /moodlebuddy\.com\/install|downloadhelper\.net\/welcome|darkreader\.org\/help|wappalyzer\.com\/installed|bitwarden\.com\/browser-start|chrome-extension:\/\/[a-p]{32}\/help\//;
    await sleep(4000);
    try {
      const pages = await (await fetch(BASE + '/json/list')).json();
      for (const t of pages) {
        if (t.type === 'page' && ONBOARDING.test(t.url)) {
          await fetch(BASE + '/json/close/' + t.id, { method: 'PUT' });
        }
      }
    } catch (e) { console.error('nettoyage onglets : ' + e.message); }
  '';

  wrapper = pkgs.writeShellScript "chrome-hermes" ''
    CHROME=${lib.escapeShellArg chrome}
    PROFILE="$HOME/.chrome-hermes-agent"
    /bin/mkdir -p "$PROFILE"
    # Une instance agent traîne déjà ? Attendre son départ : deux process sur
    # le même profil, le second est absorbé par le premier et perd ses flags.
    while /usr/bin/pgrep -f "^${chrome} .*--user-data-dir=$PROFILE" >/dev/null; do
      sleep 15
    done
    "$CHROME" \
      --user-data-dir="$PROFILE" \
      --remote-debugging-port=9222 \
      --remote-debugging-address=127.0.0.1 \
      --no-first-run \
      --no-default-browser-check \
      --restore-last-session \
      --disable-blink-features=AutomationControlled \
      --disable-features=Translate \
      --password-store=basic &
    CHROME_PID=$!
    # Extensions : Chromium ne garde pas les unpacked d'un lancement à l'autre
    # (voir l'en-tête). Le loader sort tout seul si le port reste fermé.
    ${node}/bin/node ${extLoader} >/dev/null 2>&1 || true
    wait "$CHROME_PID"
  '';
in {
  launchd.user.agents.chrome-hermes = {
    serviceConfig = {
      ProgramArguments = ["${wrapper}"];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      ProcessType = "Interactive";
      StandardOutPath = "/tmp/chrome-hermes.log";
      StandardErrorPath = "/tmp/chrome-hermes.err";
    };
  };
}
