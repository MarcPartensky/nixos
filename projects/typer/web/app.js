/* typer — browser typing trainer.
 *
 * Front-end only for solo drills: no build step, no network call except the
 * word lists served from the same origin, scores in localStorage. The race
 * mode (race.js) is the only part that talks to the server, on /ws.
 *
 * Everything the user reads goes through t(): the UI ships in French and
 * English, picked from ?lang=, localStorage, then the browser language.
 */
'use strict';

(() => {
  // ---------------------------------------------------------------- data ---

  const LANGS = {
    french200: { label: 'français 200', group: 'Français', file: 'lang/french200' },
    french1000: { label: 'français 1000', group: 'Français', file: 'lang/french1000' },
    french200ascii: {
      label: 'français 200 sans accents',
      group: 'Français',
      file: 'lang/french200',
      ascii: true,
    },
    french1000ascii: {
      label: 'français 1000 sans accents',
      group: 'Français',
      file: 'lang/french1000',
      ascii: true,
    },
    english200: { label: 'english 200', group: 'English', file: 'lang/english200' },
    english1000: { label: 'english 1000', group: 'English', file: 'lang/english1000' },
    rust: { label: 'rust', group: 'Code', file: 'lang/rust' },
    python: { label: 'python', group: 'Code', file: 'lang/python' },
    javascript: { label: 'javascript', group: 'Code', file: 'lang/javascript' },
    sql: { label: 'sql', group: 'Code', file: 'lang/sql' },
  };

  const MODES = [
    { id: 'time', key: 'mode.time' },
    { id: 'words', key: 'mode.words' },
    { id: 'quote', key: 'mode.quote' },
    { id: 'custom', key: 'mode.custom' },
  ];

  const AMOUNTS = { time: [15, 30, 60, 120], words: [10, 25, 50, 100] };

  const QUOTES = [
    {
      lang: 'fr',
      text:
        "La simplicité est la sophistication suprême. Ce qui est simple est toujours faux, ce qui est compliqué est inutilisable.",
      source: 'Paul Valéry',
    },
    {
      lang: 'fr',
      text:
        "Il faut beaucoup de chaos en soi pour enfanter une étoile qui danse. On ne se débarrasse pas d'une chose en la refusant, on s'en débarrasse en la traversant.",
      source: 'Nietzsche',
    },
    {
      lang: 'fr',
      text:
        "Le temps ne passe pas, il s'accumule. Nous croyons avancer dans un couloir, alors que nous remplissons une pièce.",
      source: 'Sylvain Tesson',
    },
    {
      lang: 'fr',
      text:
        "L'ordinateur est un outil. Il ne remplace ni le jugement ni la mémoire, il déplace l'effort vers la conception.",
      source: 'Edsger Dijkstra',
    },
    {
      lang: 'fr',
      text:
        "La dactylographie au toucher ne consiste pas à taper vite, mais à ne plus regarder ses mains. La vitesse n'est qu'une conséquence.",
      source: 'typer',
    },
    {
      lang: 'fr',
      text: "Ce qui se conçoit bien s'énonce clairement, et les mots pour le dire arrivent aisément.",
      source: 'Nicolas Boileau',
    },
    {
      lang: 'fr',
      text: 'Un clavier bien tenu est un clavier qu\'on oublie. Les doigts savent, la tête passe à autre chose.',
      source: 'typer',
    },
    {
      lang: 'fr',
      text: "La lecture d'une liste de mots n'apprend rien, la répétition d'une ligne entière forme la main.",
      source: 'typer',
    },
    {
      lang: 'en',
      text:
        'Programs must be written for people to read, and only incidentally for machines to execute. Simplicity is prerequisite for reliability.',
      source: 'Harold Abelson',
    },
    {
      lang: 'en',
      text:
        'There are only two hard things in computer science: cache invalidation, naming things, and off-by-one errors.',
      source: 'Martin Fowler',
    },
    {
      lang: 'en',
      text:
        'Typing without looking is not about speed. Speed is what happens once your hands stop asking your eyes for permission.',
      source: 'typer',
    },
    {
      lang: 'en',
      text:
        'Simplicity is the ultimate sophistication. What is simple is always wrong, what is complicated is unusable.',
      source: 'Paul Valéry',
    },
  ];

  const FALLBACK_WORDS = (
    'the of and a to in is you that it he was for on are as with his they at be this ' +
    'have from or one had by word but not what all were we when your can said there use ' +
    'an each which she do how their if will up other about out many then them these so ' +
    'some her would make like him into time has look two more write go see number way could'
  ).split(/\s+/).filter(Boolean);

  const LAYOUTS = {
    qwerty: {
      rows: [
        ['`', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '='],
        ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\\'],
        ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', "'"],
        ['z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/'],
      ],
    },
    azerty: {
      rows: [
        ['&', 'é', '"', "'", '(', '-', 'è', '_', 'ç', 'à', ')', '='],
        ['a', 'z', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
        ['q', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'm', 'ù', '*'],
        ['w', 'x', 'c', 'v', 'b', 'n', ',', ';', ':', '!'],
      ],
    },
    bepo: {
      rows: [
        ['$', '"', '«', '»', '(', ')', '@', '+', '-', '/', '*', '='],
        ['b', 'é', 'p', 'o', 'è', '!', 'v', 'd', 'l', 'j', 'z'],
        ['a', 'u', 'i', 'e', ',', ';', 'c', 't', 's', 'r', 'n', 'm'],
        ['ê', 'à', 'y', 'x', '.', ':', 'k', "'", 'q', 'g', 'h', 'f'],
      ],
    },
  };

  const STORE = {
    settings: 'typer.settings',
    history: 'typer.history',
    pb: 'typer.pb',
    ui: 'typer.ui',
    name: 'typer.name',
  };

  // ----------------------------------------------------------------- i18n ---

  const I18N = {
    fr: {
      'mode.time': 'temps',
      'mode.words': 'mots',
      'mode.quote': 'citation',
      'mode.custom': 'texte',
      'nav.race': 'Course',
      'nav.tui': 'Version terminal',
      'nav.history': 'Historique',
      'nav.custom': 'Texte libre',
      'config.lang': 'Langue',
      'config.layout': 'Disposition',
      'hud.seconds': 's',
      'hud.wpm': 'mots/min',
      'hud.accuracy': 'précision',
      'hud.errors': 'erreurs',
      'hud.words': 'mots',
      'stage.resume': 'Clique pour reprendre la frappe',
      'btn.restart': 'Recommencer',
      'btn.restartHint': 'Recommencer (Tab)',
      'btn.keyboard': 'Clavier',
      'btn.space': 'espace',
      'kb.next': 'prochaine touche',
      'kb.miss': 'touche fautive',
      'res.pb': 'record',
      'res.accuracy': 'Précision',
      'res.raw': 'Brut',
      'res.consistency': 'Régularité',
      'res.chars': 'Caractères',
      'res.time': 'Temps',
      'res.keys': 'Touches',
      'res.misses': 'Ratées',
      'res.again': 'Nouveau test <kbd>Tab</kbd>',
      'foot.private': 'Aucune donnée ne quitte ce navigateur hors course',
      'foot.words': 'listes de mots ttyper',
      'stats.title': 'Historique',
      'stats.records': 'Records',
      'stats.recent': 'Derniers tests',
      'stats.clear': "Effacer l'historique",
      'stats.emptyRecords': 'Aucun record pour le moment.',
      'stats.emptyRecent': 'Aucun test enregistré.',
      'stats.test': 'test',
      'stats.lang': 'langue',
      'stats.date': 'date',
      'stats.acc': 'préc.',
      'stats.cons': 'rég.',
      'custom.title': 'Texte libre',
      'custom.hint':
        "Colle un texte, un extrait de code, une liste de mots. Il devient le test en cours (nombre de mots illimité jusqu'à la fin du texte).",
      'custom.placeholder': 'Colle ton texte ici…',
      'custom.apply': 'Utiliser ce texte',
      'tui.title': 'Version terminal',
      'tui.intro':
        'Cette page est la version web. Le client terminal, typer-race, se connecte aux mêmes salles que le navigateur.',
      'tui.ttyper': 'Pour un exercice solo hors ligne, ttyper (Rust, ratatui) reste installé sur tower :',
      'tui.web': "Depuis le navigateur d'une autre machine :",
      'race.title': 'Course à plusieurs',
      'race.hint':
        "Une salle = un code de quatre caractères. Envoie le lien, n'importe qui entre sans compte ni installation.",
      'race.name': 'Ton nom',
      'race.create': 'Créer une salle',
      'race.code': 'Code de la salle',
      'race.join': 'Rejoindre',
      'race.share': 'Lien à partager :',
      'race.copy': 'Copier',
      'race.copied': 'Copié',
      'race.ready': 'Prêt',
      'race.cancel': 'Annuler',
      'race.leave': 'Quitter la salle',
      'race.rule': 'La course démarre quand tout le monde est prêt, avec le même texte pour tous.',
      'race.room': 'salle',
      'race.lobby': 'salon',
      'race.host': 'hôte',
      'race.you': 'toi',
      'race.starting': 'Départ dans',
      'race.waiting': 'En attente des autres',
      'race.racing': 'En course',
      'race.finished': 'Terminé',
      'race.final': 'Classement',
      'race.lost': 'Connexion perdue',
      'race.again': 'Rejouer',
      'race.err.room_full': 'Salle complète (12 joueurs).',
      'race.err.race_started': 'La course a déjà commencé.',
      'race.err.server_full': 'Trop de salles ouvertes, réessaie dans un instant.',
      'race.err.badcode': 'Code invalide : quatre lettres ou chiffres.',
      'race.err.no_room': "Cette salle n'existe pas (ou plus). Vérifie le code.",
      'race.err.name': "Choisis d'abord un nom.",
      'race.err.closed': 'Connexion perdue. Rouvre le salon pour rejoindre.',
      'race.players': 'Joueurs',
      'race.notReady': 'pas prêt',
      'race.isReady': 'prêt',
      'race.needMore': "en attente d'un autre joueur",
      'race.readyOf': '{ready}/{total} prêts',
    },
    en: {
      'mode.time': 'time',
      'mode.words': 'words',
      'mode.quote': 'quote',
      'mode.custom': 'text',
      'nav.race': 'Race',
      'nav.tui': 'Terminal client',
      'nav.history': 'History',
      'nav.custom': 'Custom text',
      'config.lang': 'Language',
      'config.layout': 'Layout',
      'hud.seconds': 's',
      'hud.wpm': 'wpm',
      'hud.accuracy': 'accuracy',
      'hud.errors': 'errors',
      'hud.words': 'words',
      'stage.resume': 'Click to resume typing',
      'btn.restart': 'Restart',
      'btn.restartHint': 'Restart (Tab)',
      'btn.keyboard': 'Keyboard',
      'btn.space': 'space',
      'kb.next': 'next key',
      'kb.miss': 'missed key',
      'res.pb': 'best',
      'res.accuracy': 'Accuracy',
      'res.raw': 'Raw',
      'res.consistency': 'Consistency',
      'res.chars': 'Characters',
      'res.time': 'Time',
      'res.keys': 'Keystrokes',
      'res.misses': 'Missed',
      'res.again': 'New test <kbd>Tab</kbd>',
      'foot.private': 'Nothing leaves this browser unless you join a race',
      'foot.words': 'ttyper word lists',
      'stats.title': 'History',
      'stats.records': 'Personal bests',
      'stats.recent': 'Recent tests',
      'stats.clear': 'Clear history',
      'stats.emptyRecords': 'No personal best yet.',
      'stats.emptyRecent': 'No test recorded yet.',
      'stats.test': 'test',
      'stats.lang': 'language',
      'stats.date': 'date',
      'stats.acc': 'acc.',
      'stats.cons': 'cons.',
      'custom.title': 'Custom text',
      'custom.hint':
        'Paste a text, a code snippet, a word list. It becomes the current test (unlimited words until the end of the text).',
      'custom.placeholder': 'Paste your text here…',
      'custom.apply': 'Use this text',
      'tui.title': 'Terminal client',
      'tui.intro':
        'This page is the web app. The terminal client, typer-race, joins the same rooms from a shell.',
      'tui.ttyper': 'For an offline solo drill, ttyper (Rust, ratatui) stays installed on tower:',
      'tui.web': 'From a browser on another machine:',
      'race.title': 'Multiplayer race',
      'race.hint':
        'A room is a four-character code. Send the link: anybody joins, no account, nothing to install.',
      'race.name': 'Your name',
      'race.create': 'Create a room',
      'race.code': 'Room code',
      'race.join': 'Join',
      'race.share': 'Link to share:',
      'race.copy': 'Copy',
      'race.copied': 'Copied',
      'race.ready': 'Ready',
      'race.cancel': 'Cancel',
      'race.leave': 'Leave room',
      'race.rule': 'The race starts once everyone is ready, on the exact same text for all.',
      'race.room': 'room',
      'race.lobby': 'lobby',
      'race.host': 'host',
      'race.you': 'you',
      'race.starting': 'Starting in',
      'race.waiting': 'Waiting for the others',
      'race.racing': 'Racing',
      'race.finished': 'Finished',
      'race.final': 'Final ranking',
      'race.lost': 'Connection lost',
      'race.again': 'Race again',
      'race.err.room_full': 'Room is full (12 players).',
      'race.err.race_started': 'That race already started.',
      'race.err.server_full': 'Too many rooms open, try again in a moment.',
      'race.err.badcode': 'Invalid code: four letters or digits.',
      'race.err.no_room': 'No such room (or it is gone). Check the code.',
      'race.err.name': 'Pick a name first.',
      'race.err.closed': 'Connection lost. Open the lobby again to rejoin.',
      'race.players': 'Players',
      'race.notReady': 'not ready',
      'race.isReady': 'ready',
      'race.needMore': 'waiting for another player',
      'race.readyOf': '{ready}/{total} ready',
    },
  };

  let ui = 'fr';

  function detectUi() {
    const params = new URLSearchParams(location.search);
    const asked = (params.get('lang') || '').toLowerCase();
    if (asked === 'en' || asked === 'fr') return asked;
    const saved = readStore(STORE.ui, null);
    if (saved === 'en' || saved === 'fr') return saved;
    return (navigator.language || 'fr').toLowerCase().startsWith('fr') ? 'fr' : 'en';
  }

  function t(key, vars) {
    const table = I18N[ui] || I18N.fr;
    let text = table[key] !== undefined ? table[key] : I18N.fr[key];
    if (text === undefined) return key;
    if (vars) for (const [k, v] of Object.entries(vars)) text = text.replace(`{${k}}`, v);
    return text;
  }

  const locale = () => (ui === 'en' ? 'en-US' : 'fr-FR');
  const sep = () => (ui === 'en' ? '.' : ',');
  const pct = (v) => `${String(Number(v).toFixed(1)).replace('.', sep())}${ui === 'en' ? '' : ' '}%`;
  const secs = (v) => `${String(Number(v).toFixed(1)).replace('.', sep())} s`;

  // ----------------------------------------------------------- elements ---

  const $ = (id) => document.getElementById(id);
  const el = {
    config: $('config'),
    groupMode: $('group-mode'),
    groupAmount: $('group-amount'),
    lang: $('lang-select'),
    layout: $('layout-select'),
    hudProgress: $('hud-progress'),
    hudProgressLabel: $('hud-progress-label'),
    hudWpm: $('hud-wpm'),
    hudAcc: $('hud-acc'),
    hudErrors: $('hud-errors'),
    stage: $('stage'),
    typewrap: $('typewrap'),
    typeview: $('typeview'),
    words: $('words'),
    caret: $('caret'),
    catcher: $('catcher'),
    focusHint: $('focus-hint'),
    results: $('results'),
    resWpm: $('res-wpm'),
    resPb: $('res-pb'),
    resAcc: $('res-acc'),
    resRaw: $('res-raw'),
    resConsistency: $('res-consistency'),
    resChars: $('res-chars'),
    resTime: $('res-time'),
    resKeys: $('res-keys'),
    resMisses: $('res-misses'),
    resAgain: $('res-again'),
    keyboard: $('keyboard'),
    restart: $('btn-restart'),
    footLang: $('foot-lang'),
    pbTable: $('pb-table'),
    histTable: $('hist-table'),
    raceFinal: $('race-final'),
    raceOverlay: $('race-overlay'),
    raceCount: $('race-count'),
    raceOverlayText: $('race-overlay-text'),
    uiLang: $('ui-lang'),
  };

  const state = {
    settings: {
      mode: 'time',
      amounts: { time: 30, words: 25, race: 30 },
      lang: 'french200',
      layout: 'qwerty',
      keyboard: true,
    },
    words: [],
    wordEls: [],
    typed: [],
    wordIndex: 0,
    wrongWords: new Set(),
    started: false,
    ended: false,
    startTime: 0,
    endTime: 0,
    keysTotal: 0,
    keysError: 0,
    errorsByKey: {},
    samples: [],
    lastSample: { t: 0, chars: 0 },
    timer: null,
    pools: new Map(),
    quoteSource: '',
    customWords: [],
    keyEls: new Map(),
    wordsAppended: 0,
  };

  // A race borrows the whole engine: the server hands the word stream, the
  // clock starts on the go signal, and nothing is written to the history.
  const race = { active: false, words: [], amount: 30, saved: null, onEnd: null };

  // ------------------------------------------------------------- storage ---

  function readStore(key, fallback) {
    try {
      const raw = localStorage.getItem(key);
      return raw ? JSON.parse(raw) : fallback;
    } catch {
      return fallback;
    }
  }

  function writeStore(key, value) {
    try {
      localStorage.setItem(key, JSON.stringify(value));
    } catch {
      /* quota or private mode: scores are a nicety, never a blocker */
    }
  }

  function hasStore(key) {
    try {
      return localStorage.getItem(key) !== null;
    } catch {
      return false;
    }
  }

  function loadSettings() {
    const saved = readStore(STORE.settings, null);
    if (saved && typeof saved === 'object') {
      state.settings = {
        ...state.settings,
        ...saved,
        amounts: { ...state.settings.amounts, ...(saved.amounts || {}) },
      };
    } else {
      // First visit: the drill follows the interface language.
      state.settings.lang = ui === 'fr' ? 'french200' : 'english200';
    }
    if (!LANGS[state.settings.lang]) state.settings.lang = 'english200';
  }

  function saveSettings() {
    writeStore(STORE.settings, state.settings);
  }

  // ------------------------------------------------------------- helpers ---

  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  const rand = (n) => Math.floor(Math.random() * n);

  function sample(pool, n) {
    const out = new Array(n);
    // Avoid the immediate repetition of the last word picked: a triple "le le le"
    // in the stream makes the drill useless.
    let prev = '';
    for (let i = 0; i < n; i++) {
      let w = pool[rand(pool.length)];
      let guard = 0;
      while (w === prev && guard++ < 8) w = pool[rand(pool.length)];
      out[i] = w;
      prev = w;
    }
    return out;
  }

  function tokenize(text) {
    return text.split(/\s+/).filter(Boolean);
  }

  async function loadPool(lang) {
    if (state.pools.has(lang)) return state.pools.get(lang);
    const meta = LANGS[lang];
    let words = null;
    try {
      const res = await fetch(meta.file, { cache: 'force-cache' });
      if (res.ok) {
        const text = await res.text();
        words = tokenize(text);
      }
    } catch {
      words = null;
    }
    if (words && meta.ascii) {
      // A drill of accented words on a US physical keyboard costs an AltGr
      // chord per letter, which measures the layout, not the touch typing.
      const plain = words.filter((w) => /^[A-Za-z0-9'-]+$/.test(w));
      if (plain.length > 20) words = plain;
    }
    if (!words || words.length < 10) words = FALLBACK_WORDS;
    state.pools.set(lang, words);
    return words;
  }

  // ----------------------------------------------------------- config UI ---

  function buildConfig() {
    el.groupMode.textContent = '';
    MODES.forEach((mode) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.dataset.mode = mode.id;
      b.textContent = t(mode.key);
      b.addEventListener('click', () => setMode(mode.id));
      el.groupMode.append(b);
    });

    el.lang.textContent = '';
    const groups = new Map();
    Object.entries(LANGS).forEach(([id, meta]) => {
      if (!groups.has(meta.group)) {
        const og = document.createElement('optgroup');
        og.label = meta.group;
        groups.set(meta.group, og);
        el.lang.append(og);
      }
      const opt = document.createElement('option');
      opt.value = id;
      opt.textContent = meta.label;
      groups.get(meta.group).append(opt);
    });
  }

  function buildAmounts() {
    const mode = state.settings.mode;
    el.groupAmount.textContent = '';
    const amounts = AMOUNTS[mode];
    el.groupAmount.hidden = !amounts;
    if (!amounts) return;
    amounts.forEach((n) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.dataset.amount = String(n);
      b.textContent = String(n);
      b.addEventListener('click', () => {
        if (race.active) return;
        state.settings.amounts[mode] = n;
        saveSettings();
        syncConfig();
        newTest();
      });
      el.groupAmount.append(b);
    });
  }

  function syncConfig() {
    const mode = state.settings.mode;
    [...el.groupMode.children].forEach((b) => {
      b.setAttribute('aria-pressed', String(b.dataset.mode === mode));
    });
    const amount = state.settings.amounts[mode];
    [...el.groupAmount.children].forEach((b) => {
      b.setAttribute('aria-pressed', String(Number(b.dataset.amount) === amount));
    });
    el.lang.value = state.settings.lang;
    el.layout.value = state.settings.layout;
    el.footLang.textContent = `${LANGS[state.settings.lang].label} · ${
      LAYOUTS[state.settings.layout] ? state.settings.layout.toUpperCase() : ''
    }`;
  }

  function setMode(mode) {
    if (race.active) return;
    state.settings.mode = mode;
    saveSettings();
    buildAmounts();
    syncConfig();
    newTest();
  }

  // --------------------------------------------------------- word stream ---

  function buildKeyboard() {
    const layout = LAYOUTS[state.settings.layout];
    el.keyboard.textContent = '';
    state.keyEls.clear();
    layout.rows.forEach((row) => {
      const rowEl = document.createElement('div');
      rowEl.className = 'kb-row';
      row.forEach((k) => {
        const key = document.createElement('div');
        key.className = 'key';
        key.textContent = k;
        key.dataset.key = k;
        state.keyEls.set(k, key);
        rowEl.append(key);
      });
      el.keyboard.append(rowEl);
    });
    const spaceRow = document.createElement('div');
    spaceRow.className = 'kb-row';
    const space = document.createElement('div');
    space.className = 'key';
    space.dataset.key = ' ';
    space.style.minWidth = '12rem';
    space.textContent = t('btn.space');
    state.keyEls.set(' ', space);
    spaceRow.append(space);
    el.keyboard.append(spaceRow);

    const legend = document.createElement('div');
    legend.className = 'kb-legend';
    legend.innerHTML =
      `<span style="--dot: var(--lavender)">${esc(t('kb.next'))}</span>` +
      `<span style="--dot: rgba(243,139,168,0.8)">${esc(t('kb.miss'))}</span>`;
    el.keyboard.append(legend);
  }

  function highlightKey() {
    const expected = state.ended
      ? ''
      : (state.words[state.wordIndex] || '')[(state.typed[state.wordIndex] || '').length] || ' ';
    state.keyEls.forEach((node, k) => {
      node.dataset.hot = String(k === expected.toLowerCase());
    });
  }

  function renderErrors() {
    state.keyEls.forEach((node, k) => {
      node.dataset.err = String(Boolean(state.errorsByKey[k]));
    });
  }

  function paintWord(i) {
    const word = state.words[i];
    const typed = state.typed[i] || '';
    const node = state.wordEls[i];
    if (!node || word === undefined) return;
    const len = Math.max(word.length, typed.length);
    let html = '';
    for (let j = 0; j < len; j++) {
      const expected = word[j];
      const got = typed[j];
      if (expected === undefined) {
        html += `<span class="ch extra">${esc(got)}</span>`;
        continue;
      }
      if (got === undefined) {
        html += `<span class="ch">${esc(expected)}</span>`;
        continue;
      }
      const ok = got === expected;
      html += `<span class="ch ${ok ? 'ok' : 'bad'}${expected === ' ' ? ' space' : ''}">${esc(
        expected
      )}</span>`;
    }
    node.innerHTML = html;
    const done = i < state.wordIndex;
    node.classList.toggle('done', done);
    node.classList.toggle('active', i === state.wordIndex);
    node.classList.toggle('wrong', done && state.wrongWords.has(i));
  }

  function paintAll() {
    for (let i = 0; i < state.words.length; i++) paintWord(i);
    placeCaret();
    highlightKey();
  }

  function appendWords(count) {
    const pool = state.pools.get(state.settings.lang) || FALLBACK_WORDS;
    const fresh = sample(pool, count);
    const start = state.words.length;
    fresh.forEach((w, k) => {
      state.words.push(w);
      const node = document.createElement('span');
      node.className = 'word';
      node.dataset.i = String(start + k);
      el.words.append(node);
      state.wordEls.push(node);
    });
    for (let i = start; i < state.words.length; i++) paintWord(i);
  }

  function placeCaret() {
    const node = state.wordEls[state.wordIndex];
    if (!node) return;
    const typed = state.typed[state.wordIndex] || '';
    const style = getComputedStyle(el.words);
    const fontSize = parseFloat(style.fontSize) || 24;
    const lineBox = parseFloat(style.lineHeight) || fontSize * 1.9;
    const caretH = fontSize * 1.3;
    const atEnd = typed.length >= node.children.length;
    const target = atEnd ? null : node.children[typed.length];
    // offsetLeft/offsetTop are layout coordinates: the caret lives inside the
    // translated word container, so it scrolls with the text and never drifts
    // during the scroll animation.
    const left = atEnd ? node.offsetLeft + node.offsetWidth : target.offsetLeft;
    const top = (atEnd ? node.offsetTop : target.offsetTop) + (lineBox - caretH) / 2;
    el.caret.style.height = `${caretH}px`;
    el.caret.style.left = `${left - 1}px`;
    el.caret.style.top = `${top}px`;
  }

  function scrollToActive() {
    const node = state.wordEls[state.wordIndex];
    const first = state.wordEls[0];
    if (!node || !first) return;
    const style = getComputedStyle(el.words);
    const lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.9;
    const line = Math.round((node.offsetTop - first.offsetTop) / lineHeight);
    const shift = Math.max(0, line - 1) * lineHeight;
    el.words.style.transform = `translateY(${-shift}px)`;
  }

  const timedMode = () => state.settings.mode === 'time' || state.settings.mode === 'race';

  function amountOf(mode) {
    return mode === 'race' ? state.settings.amounts.race : state.settings.amounts.time;
  }

  function resetHud() {
    el.hudWpm.textContent = '0';
    el.hudAcc.textContent = ui === 'en' ? '100%' : '100 %';
    el.hudErrors.textContent = '0';
    el.hudErrors.dataset.zero = 'true';
    if (timedMode()) {
      el.hudProgress.textContent = String(amountOf(state.settings.mode));
      el.hudProgressLabel.textContent = t('hud.seconds');
    } else {
      el.hudProgress.textContent = '0';
      el.hudProgressLabel.textContent = `/ ${state.words.length || 0} ${t('hud.words')}`;
    }
  }

  function clearRun() {
    stopTimer();
    state.started = false;
    state.ended = false;
    state.wordIndex = 0;
    state.typed = [];
    state.wrongWords = new Set();
    state.keysTotal = 0;
    state.keysError = 0;
    state.errorsByKey = {};
    state.samples = [];
    state.lastSample = { t: 0, chars: 0 };
    state.quoteSource = '';
    state.wordsAppended = 0;
    el.results.hidden = true;
    el.raceFinal.hidden = true;
    el.raceFinal.innerHTML = '';
    el.resAgain.hidden = false;
    el.restart.hidden = false;
    el.words.style.transform = 'translateY(0)';
    el.words.textContent = '';
    el.words.append(el.caret); // the caret lives in the stream: keep it
    state.words = [];
    state.wordEls = [];
    el.catcher.value = '';
    el.caret.style.opacity = '';
    el.stage.dataset.inactive = 'true';
    el.config.dataset.locked = 'false';
    resetHud();
  }

  function mountStream(words) {
    state.words = words.slice();
    state.wordEls = state.words.map((w, i) => {
      const node = document.createElement('span');
      node.className = 'word';
      node.dataset.i = String(i);
      node.textContent = w;
      el.words.append(node);
      return node;
    });
    paintAll();
    if (!timedMode()) {
      el.hudProgressLabel.textContent = `/ ${state.words.length} ${t('hud.words')}`;
    }
    requestAnimationFrame(() => {
      scrollToActive();
      placeCaret();
      requestAnimationFrame(placeCaret);
      setTimeout(() => {
        scrollToActive();
        placeCaret();
      }, 60);
    });
    renderErrors();
    focusCatcher();
  }

  async function newTest() {
    if (race.active) return;
    clearRun();

    const mode = state.settings.mode;
    const lang = state.settings.lang;

    if (mode === 'custom' && state.customWords.length) {
      state.words = state.customWords.slice();
    } else if (mode === 'quote') {
      const quotes = QUOTES.filter((q) => (ui === 'fr' ? q.lang === 'fr' : q.lang === 'en'));
      const quote = quotes[rand(quotes.length)] || QUOTES[0];
      state.quoteSource = quote.source;
      state.words = tokenize(quote.text);
    } else {
      const pool = await loadPool(lang);
      if (race.active) return; // a race took over while the pool was loading
      state.words = sample(pool, mode === 'words' ? state.settings.amounts.words : 120);
    }

    mountStream(state.words);
  }

  // ---------------------------------------------------------------- input ---

  function focusCatcher() {
    el.catcher.focus({ preventScroll: true });
  }

  function startTimer() {
    if (state.started) return;
    state.started = true;
    state.startTime = performance.now();
    state.lastSample = { t: 0, chars: 0 };
    el.stage.dataset.inactive = 'false';
    state.timer = setInterval(tick, 120);
  }

  function stopTimer() {
    if (state.timer) clearInterval(state.timer);
    state.timer = null;
  }

  function typedChars() {
    let n = 0;
    for (let i = 0; i <= state.wordIndex && i < state.typed.length; i++) {
      n += (state.typed[i] || '').length;
    }
    return n;
  }

  function correctChars() {
    let n = 0;
    for (let i = 0; i < state.typed.length; i++) {
      const typed = state.typed[i] || '';
      const word = state.words[i] || '';
      for (let j = 0; j < typed.length; j++) if (typed[j] === word[j]) n++;
    }
    return n;
  }

  function elapsed() {
    if (!state.started) return 0;
    const end = state.ended && state.endTime ? state.endTime : performance.now();
    return Math.max(0.001, (end - state.startTime) / 1000);
  }

  function wpmNow() {
    const mins = elapsed() / 60;
    return Math.round(correctChars() / 5 / mins);
  }

  function accuracy() {
    if (!state.keysTotal) return 100;
    return Math.max(0, 100 * (1 - state.keysError / state.keysTotal));
  }

  function tick() {
    const seconds = elapsed();
    const mode = state.settings.mode;
    if (timedMode()) {
      const left = Math.max(0, amountOf(mode) - seconds);
      el.hudProgress.textContent = String(Math.ceil(left));
      el.hudProgressLabel.textContent = t('hud.seconds');
      if (left <= 0) {
        finish();
        return;
      }
    } else {
      el.hudProgress.textContent = String(Math.min(state.wordIndex + 1, state.words.length));
      el.hudProgressLabel.textContent = `/ ${state.words.length} ${t('hud.words')}`;
    }
    el.hudWpm.textContent = String(wpmNow());
    el.hudAcc.textContent = pct(accuracy());
    el.hudErrors.textContent = String(state.keysError);
    el.hudErrors.dataset.zero = String(state.keysError === 0);

    // One WPM sample per second, used for the consistency score.
    const chars = correctChars();
    const dt = seconds - state.lastSample.t;
    if (dt >= 1) {
      const dw = chars - state.lastSample.chars;
      state.samples.push((dw / 5) * (60 / dt));
      state.lastSample = { t: seconds, chars };
    }
  }

  function feedChar(ch) {
    if (state.ended) return;
    if (ch === '\n' || ch === '\r') return;
    if (!state.started) startTimer();
    if (ch === ' ') {
      typeSpace();
      return;
    }
    const word = state.words[state.wordIndex];
    if (word === undefined) return;
    const typed = state.typed[state.wordIndex] || '';
    state.typed[state.wordIndex] = typed + ch;
    state.keysTotal++;
    const expected = word[typed.length];
    if (ch !== expected) {
      state.keysError++;
      state.errorsByKey[expected === undefined ? ch : expected] =
        (state.errorsByKey[expected === undefined ? ch : expected] || 0) + 1;
      state.wrongWords.add(state.wordIndex);
    }
    paintWord(state.wordIndex);
    placeCaret();
    highlightKey();
    renderErrors();

    // Words mode ends as soon as the last word is typed without error.
    const last = state.wordIndex === state.words.length - 1;
    if (last && state.settings.mode === 'words' && ch === expected) {
      if ((state.typed[state.wordIndex] || '') === word) finish();
    }
  }

  function typeSpace() {
    const word = state.words[state.wordIndex];
    if (word === undefined) return;
    const typed = state.typed[state.wordIndex] || '';
    if (typed.length === 0) return;
    state.keysTotal++;
    if (typed !== word) {
      state.keysError++;
      state.wrongWords.add(state.wordIndex);
      const expected = word[typed.length] === undefined ? ' ' : word[typed.length];
      state.errorsByKey[expected] = (state.errorsByKey[expected] || 0) + 1;
    }
    state.typed[state.wordIndex] = typed;
    paintWord(state.wordIndex);
    advance();
  }

  function advance() {
    const previous = state.wordIndex;
    state.wordIndex++;
    // Repaint the word we just left: paintWord() is the only place that
    // clears the .active state, and it ran while the word was still current.
    if (previous < state.words.length) paintWord(previous);
    if (state.wordIndex >= state.words.length) {
      if (state.settings.mode === 'time') {
        appendWords(40);
      } else {
        finish();
        return;
      }
    } else if (state.settings.mode === 'time' && state.words.length - state.wordIndex < 20) {
      appendWords(40);
    }
    paintWord(state.wordIndex);
    placeCaret();
    scrollToActive();
    highlightKey();
  }

  function backspace() {
    if (state.ended || !state.started) return;
    const typed = state.typed[state.wordIndex] || '';
    if (typed.length) {
      state.typed[state.wordIndex] = typed.slice(0, -1);
    } else if (state.wordIndex > 0) {
      const prev = state.wordIndex - 1;
      const prevWord = state.words[prev];
      const prevTyped = state.typed[prev] || '';
      if (prevTyped === prevWord) return; // only step back into a word that needs fixing
      state.wordIndex = prev;
      state.typed[prev] = prevTyped.slice(0, -1);
      paintWord(prev);
    }
    paintWord(state.wordIndex);
    placeCaret();
    scrollToActive();
    highlightKey();
  }

  // -------------------------------------------------------------- finish ---

  function consistency() {
    const s = state.samples.filter((v) => Number.isFinite(v));
    if (s.length < 3) return null;
    const mean = s.reduce((a, b) => a + b, 0) / s.length;
    if (mean <= 0) return null;
    const variance = s.reduce((a, b) => a + (b - mean) ** 2, 0) / s.length;
    const cv = Math.sqrt(variance) / mean;
    return Math.max(0, Math.min(100, Math.round(100 * (1 - cv))));
  }

  function pbKey() {
    const mode = state.settings.mode;
    const amount =
      mode === 'time' || mode === 'words'
        ? state.settings.amounts[mode]
        : mode === 'custom'
        ? 'custom'
        : 'quote';
    return `${mode}:${amount}:${state.settings.lang}`;
  }

  function finish() {
    if (state.ended) return;
    stopTimer();
    state.ended = true;
    state.endTime = performance.now();
    el.stage.dataset.inactive = 'true';

    const seconds = elapsed();
    const wpm = wpmNow();
    const acc = accuracy();
    const cons = consistency();
    const correct = correctChars();
    const typed = typedChars();

    el.resWpm.textContent = String(wpm);
    el.resAcc.textContent = pct(acc);
    el.resRaw.textContent = `${Math.round(typed / 5 / (seconds / 60))}`;
    el.resConsistency.textContent = cons === null ? '—' : `${cons} %`;
    el.resChars.textContent = `${correct} / ${Math.max(0, typed - correct)}`;
    el.resTime.textContent = secs(seconds);
    el.resKeys.textContent = String(state.keysTotal);
    el.resMisses.textContent = String(state.keysError);

    // Freeze the live HUD on the final numbers, otherwise the header keeps the
    // last tick (a slightly lower WPM) and contradicts the result panel.
    el.hudWpm.textContent = String(wpm);
    el.hudAcc.textContent = pct(acc);
    el.hudErrors.textContent = String(state.keysError);
    el.hudErrors.dataset.zero = String(state.keysError === 0);
    if (timedMode()) {
      el.hudProgress.textContent = '0';
      el.hudProgressLabel.textContent = t('hud.seconds');
    } else {
      el.hudProgress.textContent = String(state.words.length);
      el.hudProgressLabel.textContent = `/ ${state.words.length} ${t('hud.words')}`;
    }
    el.restart.hidden = true;
    el.resAgain.hidden = race.active; // a race is restarted from the ranking
    el.caret.style.opacity = '0';

    const snapshot = {
      wpm,
      acc: Number(acc.toFixed(1)),
      chars: correct,
      typed,
      seconds: Number(seconds.toFixed(1)),
      errors: state.keysError,
      word: state.wordIndex,
    };

    if (race.active) {
      // A race is not a personal best: same stream for everybody, and the
      // ranking comes from the server.
      el.resPb.hidden = true;
      el.results.hidden = false;
      el.config.dataset.locked = 'true';
      highlightKey();
      if (race.onEnd) race.onEnd(snapshot);
      return;
    }

    const pb = readStore(STORE.pb, {});
    const key = pbKey();
    const isPb = wpm > (pb[key] || 0);
    if (isPb) {
      pb[key] = wpm;
      writeStore(STORE.pb, pb);
    }
    el.resPb.hidden = !isPb;

    const history = readStore(STORE.history, []);
    history.unshift({
      ts: Date.now(),
      mode: state.settings.mode,
      amount:
        state.settings.mode === 'time' || state.settings.mode === 'words'
          ? state.settings.amounts[state.settings.mode]
          : null,
      lang: state.settings.lang,
      layout: state.settings.layout,
      wpm,
      raw: Math.round(typed / 5 / (seconds / 60)),
      acc: Number(acc.toFixed(1)),
      consistency: cons,
      seconds: Number(seconds.toFixed(1)),
      errors: state.keysError,
    });
    writeStore(STORE.history, history.slice(0, 200));

    el.results.hidden = false;
    el.config.dataset.locked = 'false';
    highlightKey();
    el.results.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  // --------------------------------------------------------------- race ---

  function startRace(opts) {
    if (!opts || !Array.isArray(opts.words) || !opts.words.length) return;
    if (!race.active) {
      race.saved = {
        mode: state.settings.mode,
        amounts: { ...state.settings.amounts },
        lang: state.settings.lang,
      };
    }
    race.active = true;
    race.words = opts.words.slice();
    race.amount = Number(opts.amount) || 30;
    state.settings.mode = 'race';
    state.settings.amounts.race = race.amount;

    clearRun();
    el.config.dataset.locked = 'true';
    mountStream(race.words);

    // The clock starts on the go signal, not on the first key: everybody is
    // measured over the same window.
    state.started = true;
    state.startTime = performance.now();
    state.lastSample = { t: 0, chars: 0 };
    el.stage.dataset.inactive = 'false';
    stopTimer();
    state.timer = setInterval(tick, 120);
    focusCatcher();
  }

  function freezeRace() {
    if (!race.active) return;
    if (!state.ended) finish();
    el.stage.dataset.inactive = 'true';
  }

  function exitRace() {
    if (!race.active) return;
    race.active = false;
    race.onEnd = null;
    race.words = [];
    const saved = race.saved;
    race.saved = null;
    if (saved) {
      state.settings.mode = saved.mode === 'race' ? 'time' : saved.mode;
      state.settings.amounts = { ...state.settings.amounts, ...saved.amounts };
      state.settings.lang = saved.lang;
    }
    buildAmounts();
    syncConfig();
    newTest();
  }

  function progress() {
    return {
      word: state.wordIndex,
      chars: correctChars(),
      wpm: wpmNow(),
      acc: Number(accuracy().toFixed(1)),
      done: state.ended,
    };
  }

  // ------------------------------------------------------------ dialogs ---

  function measure(mode, amount) {
    if (mode === 'time' || mode === 'race') return `${amount} ${t('hud.seconds')}`;
    if (mode === 'words') return `${amount} ${t('hud.words')}`;
    return mode;
  }

  function renderHistory() {
    const pb = readStore(STORE.pb, {});
    const history = readStore(STORE.history, []);

    el.pbTable.innerHTML = '';
    const pbEntries = Object.entries(pb).sort((a, b) => b[1] - a[1]);
    if (!pbEntries.length) {
      el.pbTable.innerHTML = `<tr><td class="empty">${esc(t('stats.emptyRecords'))}</td></tr>`;
    } else {
      el.pbTable.innerHTML =
        `<tr><th>${esc(t('stats.test'))}</th><th>${esc(t('stats.lang'))}</th><th>${esc(
          t('hud.wpm')
        )}</th></tr>` +
        pbEntries
          .slice(0, 12)
          .map(([k, v]) => {
            const [mode, amount, lang] = k.split(':');
            const label = mode === 'time' || mode === 'words' ? measure(mode, amount) : mode;
            return `<tr><td>${esc(label)}</td><td>${esc(
              (LANGS[lang] || {}).label || lang
            )}</td><td class="num wpm">${v}</td></tr>`;
          })
          .join('');
    }

    el.histTable.innerHTML = '';
    if (!history.length) {
      el.histTable.innerHTML = `<tr><td class="empty">${esc(t('stats.emptyRecent'))}</td></tr>`;
      return;
    }
    el.histTable.innerHTML =
      `<tr><th>${esc(t('stats.date'))}</th><th>${esc(t('stats.test'))}</th><th>${esc(
        t('stats.lang')
      )}</th><th>${esc(t('hud.wpm'))}</th><th>${esc(t('stats.acc'))}</th><th>${esc(
        t('stats.cons')
      )}</th></tr>` +
      history
        .slice(0, 40)
        .map((h) => {
          const date = new Date(h.ts).toLocaleString(locale(), {
            day: '2-digit',
            month: '2-digit',
            hour: '2-digit',
            minute: '2-digit',
          });
          const label =
            h.mode === 'time' || h.mode === 'words' ? measure(h.mode, h.amount) : h.mode;
          return `<tr><td>${esc(date)}</td><td>${esc(label)}</td><td>${esc(
            (LANGS[h.lang] || {}).label || h.lang
          )}</td><td class="num wpm">${h.wpm}</td><td class="num">${pct(
            h.acc
          )}</td><td class="num">${h.consistency === null ? '—' : h.consistency + ' %'}</td></tr>`;
        })
        .join('');
  }

  function openDialog(id) {
    const dlg = $(id);
    if (!dlg) return;
    if (id === 'dlg-stats') renderHistory();
    if (!dlg.open) dlg.showModal();
  }

  // ----------------------------------------------------------- language ---

  function applyI18n() {
    document.documentElement.lang = ui;
    document.querySelectorAll('[data-i18n]').forEach((node) => {
      node.textContent = t(node.dataset.i18n);
    });
    document.querySelectorAll('[data-i18n-title]').forEach((node) => {
      node.title = t(node.dataset.i18nTitle);
    });
    const placeholder = document.getElementById('custom-text');
    if (placeholder) placeholder.placeholder = t('custom.placeholder');
    el.resAgain.innerHTML = t('res.again');
    if (el.uiLang) el.uiLang.textContent = ui === 'fr' ? 'EN' : 'FR';
    buildConfig();
    buildKeyboard();
    syncConfig();
    if (!race.active) resetHud();
  }

  function setUi(next) {
    ui = next;
    writeStore(STORE.ui, ui);
    applyI18n();
    if (!race.active) newTest();
  }

  // --------------------------------------------------------------- wiring ---

  function wire() {
    el.lang.addEventListener('change', () => {
      if (race.active) {
        el.lang.value = state.settings.lang;
        return;
      }
      state.settings.lang = el.lang.value;
      saveSettings();
      syncConfig();
      newTest();
    });
    el.layout.addEventListener('change', () => {
      state.settings.layout = el.layout.value;
      saveSettings();
      buildKeyboard();
      syncConfig();
      if (!race.active) newTest();
    });

    document.querySelectorAll('[data-dialog]').forEach((b) => {
      b.addEventListener('click', () => openDialog(b.dataset.dialog));
    });

    el.uiLang.addEventListener('click', () => setUi(ui === 'fr' ? 'en' : 'fr'));

    el.restart.addEventListener('click', () => {
      if (!race.active) newTest();
    });
    el.resAgain.addEventListener('click', () => {
      if (!race.active) newTest();
    });

    $('btn-keyboard').addEventListener('click', (e) => {
      const on = e.currentTarget.getAttribute('aria-pressed') !== 'true';
      e.currentTarget.setAttribute('aria-pressed', String(on));
      el.keyboard.hidden = !on;
      state.settings.keyboard = on;
      saveSettings();
      if (!state.ended) requestAnimationFrame(placeCaret);
    });

    $('clear-history').addEventListener('click', () => {
      localStorage.removeItem(STORE.history);
      localStorage.removeItem(STORE.pb);
      renderHistory();
    });

    $('custom-apply').addEventListener('click', () => {
      const text = $('custom-text').value.trim();
      if (!text) return;
      state.customWords = tokenize(text);
      state.settings.mode = 'custom';
      saveSettings();
      buildAmounts();
      syncConfig();
      $('dlg-custom').close();
      newTest();
    });

    // Printable characters and space come from the input event (works with
    // IMEs and mobile keyboards); control keys come from keydown. Never both
    // for the same character.
    el.catcher.addEventListener('input', () => {
      const text = el.catcher.value;
      el.catcher.value = '';
      for (const ch of text) feedChar(ch);
    });

    window.addEventListener('keydown', (e) => {
      // Inside a dialog, leave Tab/Escape/typing to the dialog itself.
      if (document.querySelector('dialog[open]')) return;
      if (e.key === 'Tab' || e.key === 'Escape') {
        e.preventDefault();
        if (!race.active) newTest();
        return;
      }
      if (e.key === 'Backspace') {
        e.preventDefault();
        backspace();
        return;
      }
      // Keep focus on the catcher whenever the page is in test mode.
      if (document.activeElement !== el.catcher && e.key.length === 1) focusCatcher();
    });

    el.catcher.addEventListener('focus', () => {
      el.focusHint.hidden = true;
    });
    el.catcher.addEventListener('blur', () => {
      if (!state.ended && !race.active) el.focusHint.hidden = false;
    });
    el.focusHint.addEventListener('click', focusCatcher);
    el.typewrap.addEventListener('click', focusCatcher);

    window.addEventListener('resize', () => {
      placeCaret();
      scrollToActive();
    });

    document.querySelectorAll('dialog').forEach((d) => {
      d.addEventListener('close', () => {
        if (!state.ended && !race.active) focusCatcher();
      });
    });
  }

  async function init() {
    ui = detectUi();
    loadSettings();
    applyI18n();
    wire();
    el.keyboard.hidden = !state.settings.keyboard;
    $('btn-keyboard').setAttribute('aria-pressed', String(state.settings.keyboard));
    buildAmounts();
    syncConfig();
    await newTest();
    if (state.settings.mode === 'quote') el.config.dataset.locked = 'false';
  }

  // The race module drives the engine through this narrow surface.
  window.typer = {
    startRace,
    freezeRace,
    exitRace,
    progress,
    openDialog,
    t,
    langMeta: LANGS,
    getState: () => state,
  };

  init();
})();
