#!/usr/bin/env python3
# droplify.py - stdlib only, aucune dépendance

import http.server
import os
import uuid
import cgi
import json
from pathlib import Path

DATA_DIR = Path(os.environ.get("DATA_DIR", "/var/lib/droplify"))
BASE_URL  = os.environ.get("BASE_URL", "http://localhost:8080")
PORT      = int(os.environ.get("PORT", "8080"))

UPLOAD_PAGE = """<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>droplify</title>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=DM+Sans:wght@300;400;500&display=swap');

    :root {
      --bg: #fafaf8;
      --surface: #ffffff;
      --border: #e8e6e0;
      --accent: #1a1a1a;
      --accent2: #6366f1;
      --muted: #9e9b93;
      --success: #16a34a;
      --radius: 6px;
    }

    * { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: 'DM Sans', sans-serif;
      background: var(--bg);
      color: var(--accent);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 24px;
    }

    header {
      position: fixed;
      top: 0; left: 0; right: 0;
      padding: 18px 32px;
      display: flex;
      align-items: center;
      gap: 10px;
      border-bottom: 1px solid var(--border);
      background: var(--bg);
    }

    .logo {
      font-family: 'Space Mono', monospace;
      font-size: 0.95rem;
      font-weight: 700;
      letter-spacing: -0.02em;
    }

    .logo span { color: var(--accent2); }

    .badge {
      font-family: 'Space Mono', monospace;
      font-size: 0.65rem;
      background: var(--accent);
      color: var(--bg);
      padding: 2px 6px;
      border-radius: 3px;
      letter-spacing: 0.05em;
    }

    main {
      width: 100%;
      max-width: 480px;
      display: flex;
      flex-direction: column;
      gap: 20px;
    }

    h1 {
      font-size: 1.5rem;
      font-weight: 500;
      letter-spacing: -0.03em;
      line-height: 1.2;
    }

    h1 em {
      font-style: normal;
      color: var(--muted);
    }

    #dropzone {
      border: 1.5px dashed var(--border);
      border-radius: var(--radius);
      padding: 48px 32px;
      text-align: center;
      cursor: pointer;
      transition: border-color 0.15s, background 0.15s;
      background: var(--surface);
      user-select: none;
    }

    #dropzone:hover, #dropzone.over {
      border-color: var(--accent2);
      background: #f5f5ff;
    }

    #dropzone.over { border-style: solid; }

    .drop-icon {
      font-size: 2rem;
      margin-bottom: 12px;
      display: block;
      opacity: 0.5;
    }

    .drop-label {
      font-size: 0.95rem;
      font-weight: 500;
      margin-bottom: 4px;
    }

    .drop-sub {
      font-size: 0.8rem;
      color: var(--muted);
    }

    input[type=file] { display: none; }

    #status {
      font-size: 0.85rem;
      padding: 12px 16px;
      border-radius: var(--radius);
      display: none;
      align-items: center;
      gap: 10px;
      border: 1px solid var(--border);
      background: var(--surface);
    }

    #status.visible { display: flex; }

    #status.loading { color: var(--muted); }

    #status.success {
      border-color: #bbf7d0;
      background: #f0fdf4;
      color: var(--success);
    }

    #status.error {
      border-color: #fecaca;
      background: #fef2f2;
      color: #dc2626;
    }

    #status a {
      font-family: 'Space Mono', monospace;
      font-size: 0.8rem;
      color: var(--accent2);
      text-decoration: none;
      word-break: break-all;
    }

    #status a:hover { text-decoration: underline; }

    .copy-btn {
      margin-left: auto;
      flex-shrink: 0;
      font-family: 'Space Mono', monospace;
      font-size: 0.7rem;
      padding: 4px 8px;
      border: 1px solid var(--border);
      border-radius: 3px;
      background: var(--bg);
      cursor: pointer;
      color: var(--accent);
      transition: background 0.1s;
    }

    .copy-btn:hover { background: var(--border); }

    #history {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }

    .history-label {
      font-size: 0.75rem;
      font-family: 'Space Mono', monospace;
      color: var(--muted);
      letter-spacing: 0.05em;
      text-transform: uppercase;
    }

    .history-item {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 0.82rem;
      padding: 8px 12px;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      background: var(--surface);
    }

    .history-item a {
      font-family: 'Space Mono', monospace;
      font-size: 0.75rem;
      color: var(--accent2);
      text-decoration: none;
      word-break: break-all;
      flex: 1;
    }

    .history-item a:hover { text-decoration: underline; }

    .history-item .copy-btn { margin-left: 0; }
  </style>
</head>
<body>
  <header>
    <span class="logo">drop<span>lify</span></span>
    <span class="badge">SELF-HOSTED</span>
  </header>

  <main>
    <h1>Glisse un fichier HTML<br><em>obtiens une URL.</em></h1>

    <div id="dropzone">
      <span class="drop-icon">⬆</span>
      <div class="drop-label">Glisse ici ou clique</div>
      <div class="drop-sub">.html · .htm</div>
    </div>
    <input type="file" id="file" accept=".html,.htm">

    <div id="status"></div>

    <div id="history" style="display:none">
      <div class="history-label">Cette session</div>
      <div id="history-list"></div>
    </div>
  </main>

  <script>
    const dropzone = document.getElementById('dropzone');
    const input    = document.getElementById('file');
    const status   = document.getElementById('status');
    const history  = document.getElementById('history');
    const histList = document.getElementById('history-list');

    dropzone.addEventListener('click', () => input.click());
    dropzone.addEventListener('dragover', e => { e.preventDefault(); dropzone.classList.add('over'); });
    dropzone.addEventListener('dragleave', () => dropzone.classList.remove('over'));
    dropzone.addEventListener('drop', e => {
      e.preventDefault();
      dropzone.classList.remove('over');
      upload(e.dataTransfer.files[0]);
    });
    input.addEventListener('change', () => upload(input.files[0]));

    function setStatus(type, html) {
      status.className = 'visible ' + type;
      status.innerHTML = html;
    }

    function copyBtn(url) {
      return `<button class="copy-btn" onclick="navigator.clipboard.writeText('${url}');this.textContent='✓'">copy</button>`;
    }

    async function upload(file) {
      if (!file) return;
      setStatus('loading', '<span>Upload en cours…</span>');

      const fd = new FormData();
      fd.append('file', file);

      try {
        const res  = await fetch('/upload', { method: 'POST', body: fd });
        const data = await res.json();

        if (data.url) {
          setStatus('success', `<span>Hébergé :</span> <a href="${data.url}" target="_blank">${data.url}</a>${copyBtn(data.url)}`);
          addHistory(data.url, file.name);
        } else {
          setStatus('error', `<span>Erreur : ${data.error || 'inconnue'}</span>`);
        }
      } catch (e) {
        setStatus('error', `<span>Erreur réseau</span>`);
      }
    }

    function addHistory(url, name) {
      history.style.display = 'flex';
      const item = document.createElement('div');
      item.className = 'history-item';
      item.innerHTML = `<a href="${url}" target="_blank">${url}</a>${copyBtn(url)}`;
      histList.prepend(item);
    }
  </script>
</body>
</html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        path = self.path.strip("/")

        if path == "" or path == "index.html":
            self._respond(200, "text/html", UPLOAD_PAGE.encode())
            return

        parts = path.split("/", 1)
        slug  = parts[0]
        fname = parts[1] if len(parts) > 1 else "index.html"
        fpath = DATA_DIR / slug / fname

        if not fpath.exists():
            self._respond(404, "text/plain", b"Not found")
            return

        ctype = "text/html; charset=utf-8" if fname.endswith((".html", ".htm")) else "application/octet-stream"
        self._respond(200, ctype, fpath.read_bytes())

    def do_POST(self):
        if self.path != "/upload":
            self._respond(404, "text/plain", b"Not found")
            return

        ctype, pdict = cgi.parse_header(self.headers.get("Content-Type", ""))
        if ctype != "multipart/form-data":
            self._json(400, {"error": "multipart required"})
            return

        pdict["boundary"] = bytes(pdict["boundary"], "utf-8")
        pdict["CONTENT-LENGTH"] = int(self.headers.get("Content-Length", 0))
        fields = cgi.parse_multipart(self.rfile, pdict)

        file_data = fields.get("file")
        if not file_data:
            self._json(400, {"error": "champ 'file' manquant"})
            return

        slug = uuid.uuid4().hex[:8]
        dest = DATA_DIR / slug
        dest.mkdir(parents=True, exist_ok=True)
        data = file_data[0]
        (dest / "index.html").write_bytes(data if isinstance(data, bytes) else data.encode())

        self._json(200, {"url": f"{BASE_URL}/{slug}"})

    def _respond(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self._respond(code, "application/json", body)


if __name__ == "__main__":
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"droplify sur {BASE_URL} (port {PORT})")
    server.serve_forever()
