/* typer — multiplayer races (browser client).
 *
 * A room is four characters. The server owns the word stream, the start time
 * and the ranking; this module only renders the lobby, forwards local progress
 * and hands the stream to app.js when the race starts.
 *
 * Guests need nothing: no account, no cookie, no install. The link carries the
 * code (#room=ABCD) and the socket is same-origin (/ws), so the tunnel that
 * serves the page serves the race too.
 */
'use strict';

(() => {
  const { t } = window.typer;

  const $ = (id) => document.getElementById(id);

  const el = {
    open: $('open-race'),
    dialog: $('dlg-race'),
    name: $('race-name'),
    create: $('race-create'),
    code: $('race-code-input'),
    join: $('race-join'),
    error: $('race-error'),
    share: $('race-share'),
    link: $('race-link'),
    copy: $('race-copy'),
    players: $('race-players'),
    ready: $('race-ready'),
    leave: $('race-leave'),
    section: $('race'),
    codeLabel: $('race-code'),
    status: $('race-status'),
    board: $('race-board'),
    overlay: $('race-overlay'),
    count: $('race-count'),
    overlayText: $('race-overlay-text'),
    final: $('race-final'),
  };

  const CODE_RE = /^[A-Z0-9]{4}$/;
  const STATUS_INTERVAL = 400;

  const race = {
    socket: null,
    room: null,
    me: null,
    state: null,
    pending: null,
    joining: false,
    started: false,
    shown: false,
    reported: false,
    poller: null,
    error: '',
  };

  // ------------------------------------------------------------- helpers ---

  function showError(key) {
    const message = key ? t(`race.err.${key}`) : '';
    el.error.textContent = message;
    el.error.hidden = !message;
  }

  function setBusy(busy) {
    race.joining = busy;
    [el.create, el.join].forEach((b) => {
      b.disabled = busy;
    });
  }

  function storedName() {
    try {
      const raw = localStorage.getItem('typer.name');
      if (!raw) return '';
      try {
        return String(JSON.parse(raw) || '').slice(0, 20);
      } catch {
        return raw.slice(0, 20);
      }
    } catch {
      return '';
    }
  }

  function saveName(name) {
    try {
      localStorage.setItem('typer.name', JSON.stringify(name));
    } catch {
      /* private mode: the name just does not persist */
    }
  }

  function cleanName() {
    return el.name.value.trim().slice(0, 20);
  }

  function currentLang() {
    const state = window.typer.getState();
    const lang = state.settings.lang;
    // Races are word lists only: the code lists are punctuation drills.
    return /^(english|french)(200|1000)$/.test(lang) ? lang : 'english200';
  }

  function currentAmount() {
    const state = window.typer.getState();
    const n = Number(state.settings.amounts.time) || 30;
    return [15, 30, 60, 120].includes(n) ? n : 30;
  }

  // -------------------------------------------------------------- socket ---

  function url() {
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    return `${scheme}://${location.host}/ws`;
  }

  function connect() {
    if (race.socket && (race.socket.readyState === WebSocket.OPEN || race.socket.readyState === WebSocket.CONNECTING)) {
      return Promise.resolve(race.socket);
    }
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url());
      socket.addEventListener('open', () => {
        race.socket = socket;
        if (race.pending) {
          send(race.pending);
          race.pending = null;
        }
        resolve(socket);
      });
      socket.addEventListener('message', onMessage);
      socket.addEventListener('close', onClose);
      socket.addEventListener('error', () => {
        if (socket.readyState !== WebSocket.OPEN) reject(new Error('ws'));
      });
    }).catch((err) => {
      showError('closed');
      setBusy(false);
      throw err;
    });
  }

  function send(message) {
    if (!race.socket || race.socket.readyState !== WebSocket.OPEN) {
      race.pending = message;
      return;
    }
    race.socket.send(JSON.stringify(message));
  }

  function onClose() {
    race.socket = null;
    stopPoller();
    if (race.room) {
      el.status.textContent = t('race.lost');
      window.typer.freezeRace();
      showError('closed');
      setBusy(false);
    }
  }

  function onMessage(event) {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      return;
    }
    if (!message || typeof message !== 'object') return;
    if (message.t === 'error') {
      showError(message.error || 'closed');
      setBusy(false);
      return;
    }
    if (message.t !== 'state') return;
    race.state = message;
    race.room = message.room;
    race.me = message.you;
    setBusy(false);
    showError('');
    if (!race.shown) {
      race.shown = true;
      if (!el.dialog.open) el.dialog.showModal();
    }
    render();
  }

  // -------------------------------------------------------------- joining ---

  function joinRequest(code) {
    const name = cleanName();
    if (!name) {
      showError('name');
      el.name.focus();
      return null;
    }
    saveName(name);
    return { t: 'join', room: code || '', name, lang: currentLang(), amount: currentAmount() };
  }

  function doJoin(code) {
    const request = joinRequest(code);
    if (!request) return;
    setBusy(true);
    showError('');
    race.room = code || null; // pending: the server answers with the real code
    connect()
      .then(() => send(request))
      .catch(() => setBusy(false));
  }

  function leave() {
    if (race.socket && race.socket.readyState === WebSocket.OPEN) {
      try {
        race.socket.send(JSON.stringify({ t: 'leave' }));
      } catch {
        /* closing anyway */
      }
    }
    try {
      race.socket && race.socket.close();
    } catch {
      /* already gone */
    }
    race.socket = null;
    race.room = null;
    race.state = null;
    stopPoller();
    window.typer.exitRace();
    el.section.hidden = true;
    el.overlay.hidden = true;
    el.share.hidden = true;
    el.players.textContent = '';
    el.board.textContent = '';
    el.final.hidden = true;
    el.final.textContent = '';
    if (location.hash.startsWith('#room=')) history.replaceState(null, '', location.pathname);
  }

  function ready(on) {
    send({ t: 'ready', ready: on });
  }

  function settingsChanged() {
    if (!race.room || !race.state || race.state.host !== race.me || race.state.phase !== 'lobby') return;
    send({ t: 'settings', lang: currentLang(), amount: currentAmount() });
  }

  // -------------------------------------------------------------- render ---

  function shareLink(code) {
    return `${location.origin}${location.pathname}#room=${code}`;
  }

  function renderPlayers(players) {
    const rows = players
      .slice()
      .sort((a, b) => (a.rank || 99) - (b.rank || 99) || b.chars - a.chars);
    return rows
      .map((p) => {
        const you = p.id === race.me ? ` <span class="tag">${t('race.you')}</span>` : '';
        const host = p.id === race.state.host ? ` <span class="tag">${t('race.host')}</span>` : '';
        const mark = p.ready ? '✓' : '·';
        return `<li class="${p.id === race.me ? 'me' : ''}"><span class="who">${mark} ${
          p.name
        }</span>${you}${host}</li>`;
      })
      .join('');
  }

  // In the lobby the race columns are all zero: one line per player, with the
  // ready mark, so the page itself (dialog closed) shows who actually joined
  // and who has approved.
  function renderLobbyBoard(players) {
    el.board.innerHTML = players
      .map((p) => {
        const cls = p.id === race.me ? 'race-row me' : 'race-row';
        const tags = [];
        if (p.id === race.me) tags.push(t('race.you'));
        if (p.id === race.state.host) tags.push(t('race.host'));
        const tag = tags.length ? ` <span class="tag">${tags.join(', ')}</span>` : '';
        return (
          `<li class="${cls}">` +
          `<span class="rank">${p.ready ? '✓' : '·'}</span>` +
          `<span class="who">${p.name}${tag}</span>` +
          `<span class="unit">${t(p.ready ? 'race.isReady' : 'race.notReady')}</span>` +
          `</li>`
        );
      })
      .join('');
    el.board.dataset.words = '0';
  }

  function renderBoard(players, words) {
    const rows = players.slice().sort((a, b) => (a.rank || 99) - (b.rank || 99) || b.chars - a.chars);
    const top = Math.max(1, ...rows.map((p) => p.chars));
    el.board.innerHTML = rows
      .map((p, i) => {
        const width = Math.round((100 * p.chars) / top);
        const cls = p.id === race.me ? 'race-row me' : 'race-row';
        const acc = `${p.acc}${p.acc >= 100 ? '' : ''}`;
        return (
          `<li class="${cls}">` +
          `<span class="rank">${i + 1}</span>` +
          `<span class="who">${p.name}</span>` +
          `<span class="bar"><i style="width:${width}%"></i></span>` +
          `<span class="num">${p.wpm}</span>` +
          `<span class="unit">${t('hud.wpm')}</span>` +
          `<span class="num acc">${acc}%</span>` +
          `</li>`
        );
      })
      .join('');
    el.board.dataset.words = String(words || 0);
  }

  function renderFinal(players) {
    const rows = players.slice().sort((a, b) => (a.rank || 99) - (b.rank || 99));
    el.final.hidden = false;
    el.final.innerHTML =
      `<h3>${t('race.final')}</h3>` +
      '<table class="race-table"><tr><th>#</th><th>' +
      `${t('race.players')}</th><th>${t('hud.wpm')}</th><th>${t('stats.acc')}</th></tr>` +
      rows
        .map(
          (p) =>
            `<tr class="${p.id === race.me ? 'me' : ''}"><td>${p.rank}</td><td>${p.name}</td>` +
            `<td class="num wpm">${p.wpm}</td><td class="num">${p.acc}%</td></tr>`
        )
        .join('') +
      '</table>' +
      `<div class="result-actions"><button type="button" class="primary" id="race-again">${t(
        'race.again'
      )}</button></div>`;
    const again = $('race-again');
    if (again) again.addEventListener('click', () => send({ t: 'rematch' }));
  }

  function render() {
    const s = race.state;
    if (!s) return;
    const me = s.players.find((p) => p.id === race.me);
    const code = s.room;

    el.share.hidden = false;
    el.link.value = shareLink(code);
    el.players.innerHTML = renderPlayers(s.players);
    el.codeLabel.textContent = code;
    el.section.hidden = false;
    el.section.dataset.phase = s.phase;

    // Waiting-room state of the dialog buttons.
    const ready = Boolean(me && me.ready);
    el.ready.textContent = ready ? t('race.cancel') : t('race.ready');
    el.ready.dataset.on = String(ready);
    el.ready.hidden = s.phase !== 'lobby';

    // Adopt the host's settings so the local stream lists match the race.
    if (s.phase === 'lobby' && s.host !== race.me) {
      const state = window.typer.getState();
      state.settings.lang = s.lang;
      state.settings.amounts.time = s.amount;
    }

    if (s.phase === 'lobby') {
      el.overlay.hidden = true;
      el.final.hidden = true;
      const approved = s.players.filter((p) => p.ready).length;
      const alone = s.players.length === 1;
      // A race needs two players now: say what is being waited for instead of
      // leaving a host ready in front of a room that will never start.
      el.status.textContent =
        alone && approved === 1
          ? t('race.needMore')
          : t('race.readyOf', { ready: approved, total: s.players.length });
      renderLobbyBoard(s.players);
      if (race.started || window.typer.getState().settings.mode === 'race') {
        window.typer.exitRace();
        race.started = false;
      }
    } else if (s.phase === 'countdown') {
      el.overlay.hidden = false;
      el.overlayText.textContent = t('race.racing');
      el.count.textContent = String(Math.max(1, Math.ceil(s.startsIn || 1)));
      el.status.textContent = `${t('race.starting')} ${el.count.textContent}`;
      if (el.dialog.open) el.dialog.close();
    } else if (s.phase === 'race') {
      el.overlay.hidden = true;
      el.status.textContent = t('race.racing');
      if (!race.started) {
        race.started = true;
        race.reported = false;
        el.final.hidden = true;
        if (el.dialog.open) el.dialog.close();
        window.typer.startRace({ words: s.words, amount: s.amount });
        startPoller();
      }
      renderBoard(s.players, s.words.length);
    } else if (s.phase === 'done') {
      el.overlay.hidden = true;
      el.status.textContent = t('race.finished');
      if (race.started) {
        stopPoller();
        window.typer.freezeRace();
        reportDone();
        race.started = false;
      }
      renderBoard(s.players, s.words.length);
      renderFinal(s.standings || s.players);
      el.final.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }

  // ------------------------------------------------------------- progress ---

  function startPoller() {
    stopPoller();
    race.poller = setInterval(() => {
      if (!race.socket || race.socket.readyState !== WebSocket.OPEN) return;
      const p = window.typer.progress();
      send({ t: 'progress', word: p.word, chars: p.chars, wpm: p.wpm, acc: p.acc });
    }, STATUS_INTERVAL);
  }

  function stopPoller() {
    if (race.poller) clearInterval(race.poller);
    race.poller = null;
  }

  function reportDone() {
    if (race.reported) return;
    race.reported = true;
    const p = window.typer.progress();
    send({ t: 'done', word: p.word, chars: p.chars, wpm: p.wpm, acc: p.acc });
  }

  // --------------------------------------------------------------- wiring ---

  function autofill() {
    el.name.value = storedName();
    const match = /(?:^#|&)room=([A-Za-z0-9]{4})/.exec(location.hash);
    const query = new URLSearchParams(location.search).get('room');
    const code = (match ? match[1] : query || '').toUpperCase();
    if (code) el.code.value = code;
    return code;
  }

  function openDialog() {
    const code = autofill();
    connect().catch(() => {});
    if (code && storedName()) {
      // A shared link with a name already known: straight into the room.
      doJoin(code);
      return;
    }
    if (race.state) render();
  }

  function copyLink() {
    const value = el.link.value;
    const done = () => {
      el.copy.textContent = t('race.copied');
      setTimeout(() => {
        el.copy.textContent = t('race.copy');
      }, 1400);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(value).then(done).catch(() => {
        el.link.select();
        document.execCommand('copy');
        done();
      });
      return;
    }
    el.link.select();
    document.execCommand('copy');
    done();
  }

  function wire() {
    el.open.addEventListener('click', openDialog);
    $('race-open').addEventListener('click', () => {
      if (!el.dialog.open) el.dialog.showModal();
    });

    el.create.addEventListener('click', () => doJoin(''));
    el.join.addEventListener('click', () => {
      const code = el.code.value.trim().toUpperCase();
      if (!CODE_RE.test(code)) {
        showError('badcode');
        el.code.focus();
        return;
      }
      doJoin(code);
    });
    el.code.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        el.join.click();
      }
    });
    el.name.addEventListener('change', () => saveName(cleanName()));

    el.ready.addEventListener('click', () => {
      const me = race.state && race.state.players.find((p) => p.id === race.me);
      ready(!(me && me.ready));
    });
    el.leave.addEventListener('click', leave);
    el.copy.addEventListener('click', copyLink);

    // The host changing mode/duration before the race propagates to the room.
    ['group-mode', 'group-amount'].forEach((id) =>
      $(id).addEventListener('click', () => setTimeout(settingsChanged, 0))
    );
    $('lang-select').addEventListener('change', () => setTimeout(settingsChanged, 0));

    el.dialog.addEventListener('close', () => {
      if (race.state) el.section.hidden = false;
    });

    window.addEventListener('hashchange', () => {
      const code = autofill();
      if (code && race.state === null && storedName()) doJoin(code);
    });

    // An invite link opens ready to use: straight into the room when a name is
    // already known, otherwise the dialog with the code filled in.
    const invited = autofill();
    if (invited) {
      if (storedName()) doJoin(invited);
      else if (!el.dialog.open) el.dialog.showModal();
    }
  }

  wire();
})();
