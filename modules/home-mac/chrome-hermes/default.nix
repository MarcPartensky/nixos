# Chrome "agent" of marc's Mac: a SEPARATE instance from the daily Chrome,
# driven by Hermes from tower (CDP over loopback through ssh).
#
# Why Chrome and not Firefox (measured 09/11/2026):
# - A Firefox launched with --marionette (or attached by geckodriver/Selenium)
#   advertises navigator.webdriver=true PERMANENTLY, even with no client connected,
#   and the pref dom.webdriver.enabled no longer exists since FF88: every
#   anti-bot site (Cloudflare Turnstile...) sees it as a robot. No setting
#   on the Firefox side hides it.
# - A Chrome launched WITHOUT --enable-automation (so never by ChromeDriver) has
#   navigator.webdriver=undefined. Measured on this instance: bot.sannysoft.com
#   "WebDriver missing (passed)" + "WebDriver Advanced passed", and
#   nowsecure.nl (Cloudflare) serves its content without a challenge.
# - tower's driver (skill marc-mac-operations/scripts/mac-cdp.mjs) only speaks
#   Runtime.evaluate / Page.navigate / Input.dispatch* : no
#   Runtime.enable, the classic CDP tell of Playwright/Puppeteer tools.
#
# Details:
# - Dedicated and persistent profile ~/.chrome-hermes-agent (never marc's
#   daily profile: ~/Library/Application Support/Google/Chrome).
# - CDP on 127.0.0.1:9222 only (a reachable CDP port = full control of the
#   browser). tower reaches it via a loopback ssh tunnel (19222 -> 9222).
# - Port 9333 = marc's browser; 9222 = the agent. Chrome refuses to
#   start if --remote-debugging-port is already taken, and also refuses this flag
#   on the default profile: hence the explicit --user-data-dir.
# - Window VISIBLE on marc's screen (no --headless): he sees what
#   the agent does, and logins/OAuth are typed by hand in this window.
# - KeepAlive: a Cmd+Q on the agent instance restarts it within 30 s.
#   Real stop: launchctl bootout gui/$(id -u)/org.nixos.chrome-hermes
#
# EXTENSIONS (mirror of marc's LibreWolf, measured 09/11/2026):
# - Chrome 157 IGNORES --load-extension (verified: zero extensions loaded, even
#   with --disable-features=DisableLoadExtensionCommandLineSwitch).
# - LibreWolf's .xpi do not load either (Firefox/WebExtension,
#   manifest v2, browser.* API). Only uBlock Origin no longer exists in MV2 on
#   Chrome: we take uBlock Origin Lite (MV3) and the Chrome Store versions from the
#   same editors (Bitwarden, Dark Reader, SponsorBlock, Video Speed
#   Controller, Video DownloadHelper, Wappalyzer, Get cookies.txt, Moodle
#   Buddy).
# - The only path that works: CDP `Extensions.loadUnpacked`. They do NOT
#   survive a Chrome restart, so the wrapper launches Chrome, waits for the
#   debug port then reloads the extensions on every start (so marc has
#   adblock and Bitwarden even when Hermes is not driving).
# - Installing the files (unzipped CRX):
#   `scripts/chrome-ext-install.py ~/.chrome-hermes-agent-ext <ids...>` from the
#   skill marc-mac-operations. Update = re-run this script.
# - Bitwarden: marc logs in ONCE in the agent window (password
#   typed by him), then the driver fills with `autofill` (Meta+Shift+L).
{pkgs, lib, ...}: let
  chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  node = pkgs.nodejs_22;

  extLoader = pkgs.writeText "chrome-hermes-ext.mjs" ''
    // Reloads the unpacked extensions into the agent Chrome (CDP), once
    // the debug port responds. NEVER call Runtime.enable here.
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
      } catch { /* port not open yet */ }
      if (!version) await sleep(1000);
    }
    if (!version) { console.error('CDP 9222 unreachable: extensions not loaded'); process.exit(1); }
    const ws = new WebSocket(version.webSocketDebuggerUrl);
    await new Promise((res, rej) => {
      ws.addEventListener('open', res, { once: true });
      ws.addEventListener('error', () => rej(new Error('websocket refused')), { once: true });
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
    console.log('extensions loaded: ' + ok + '/' + IDS.length);
    ws.close();
    // Each load = an "installation": the extensions open their
    // home page. We close these tabs to keep the window clean.
    const ONBOARDING = /moodlebuddy\.com\/install|downloadhelper\.net\/welcome|darkreader\.org\/help|wappalyzer\.com\/installed|bitwarden\.com\/browser-start|chrome-extension:\/\/[a-p]{32}\/help\//;
    await sleep(4000);
    try {
      const pages = await (await fetch(BASE + '/json/list')).json();
      for (const t of pages) {
        if (t.type === 'page' && ONBOARDING.test(t.url)) {
          await fetch(BASE + '/json/close/' + t.id, { method: 'PUT' });
        }
      }
    } catch (e) { console.error('tab cleanup: ' + e.message); }
  '';

  wrapper = pkgs.writeShellScript "chrome-hermes" ''
    CHROME=${lib.escapeShellArg chrome}
    PROFILE="$HOME/.chrome-hermes-agent"
    /bin/mkdir -p "$PROFILE"
    # An agent instance already lingering? Wait for it to exit: two processes on
    # the same profile, the second is absorbed by the first and loses its flags.
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
    # Extensions: Chromium does not keep the unpacked ones from one launch to the next
    # (see the header). The loader exits on its own if the port stays closed.
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
