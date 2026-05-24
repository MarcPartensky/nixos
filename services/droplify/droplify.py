#!/usr/bin/env python3
# droplify.py - stdlib only, Python 3.13+ compatible

import http.server
import os
import uuid
import json
import time
from pathlib import Path

DATA_DIR = Path(os.environ.get("DATA_DIR", "/var/lib/droplify"))
BASE_URL  = os.environ.get("BASE_URL", "http://localhost:8080")
PORT      = int(os.environ.get("PORT", "8080"))


def parse_multipart(fp, boundary: str, content_length: int) -> dict:
    data = fp.read(content_length)
    delim = ("--" + boundary).encode()
    fields = {}
    for part in data.split(delim)[1:]:
        if part.startswith(b"--"):
            break
        if part.startswith(b"\r\n"):
            part = part[2:]
        if part.endswith(b"\r\n"):
            part = part[:-2]
        if b"\r\n\r\n" not in part:
            continue
        headers_raw, body = part.split(b"\r\n\r\n", 1)
        headers = {}
        for line in headers_raw.decode("utf-8", errors="replace").split("\r\n"):
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        disp = headers.get("content-disposition", "")
        name = None
        filename = None
        for item in disp.split(";"):
            item = item.strip()
            if item.startswith("name="):
                name = item[5:].strip('"')
            if item.startswith("filename="):
                filename = item[9:].strip('"')
        if name:
            fields[name] = {"data": body, "filename": filename or "index.html"}
    return fields


def list_files():
    entries = []
    if not DATA_DIR.exists():
        return entries
    for slug_dir in sorted(DATA_DIR.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
        if not slug_dir.is_dir():
            continue
        index = slug_dir / "index.html"
        if not index.exists():
            continue
        meta_path = slug_dir / "meta.json"
        meta = {}
        if meta_path.exists():
            try:
                meta = json.loads(meta_path.read_text())
            except Exception:
                pass
        entries.append({
            "slug": slug_dir.name,
            "url": f"{BASE_URL}/{slug_dir.name}",
            "filename": meta.get("filename", "index.html"),
            "uploaded_at": meta.get("uploaded_at", int(slug_dir.stat().st_mtime)),
        })
    return entries


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
      padding: 88px 24px 48px;
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
      z-index: 10;
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

    .layout {
      width: 100%;
      max-width: 900px;
      display: grid;
      grid-template-columns: 340px 1fr;
      gap: 32px;
      align-items: start;
    }

    @media (max-width: 700px) {
      .layout { grid-template-columns: 1fr; }
    }

    /* --- LEFT PANEL --- */
    .left { display: flex; flex-direction: column; gap: 16px; }

    h1 {
      font-size: 1.4rem;
      font-weight: 500;
      letter-spacing: -0.03em;
      line-height: 1.2;
    }

    h1 em { font-style: normal; color: var(--muted); }

    #dropzone {
      border: 1.5px dashed var(--border);
      border-radius: var(--radius);
      padding: 40px 24px;
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

    .drop-icon { font-size: 1.8rem; margin-bottom: 10px; display: block; opacity: 0.4; }
    .drop-label { font-size: 0.9rem; font-weight: 500; margin-bottom: 4px; }
    .drop-sub { font-size: 0.78rem; color: var(--muted); }

    input[type=file] { display: none; }

    #status {
      font-size: 0.82rem;
      padding: 10px 14px;
      border-radius: var(--radius);
      display: none;
      align-items: center;
      gap: 8px;
      border: 1px solid var(--border);
      background: var(--surface);
    }

    #status.visible { display: flex; }
    #status.loading { color: var(--muted); }
    #status.success { border-color: #bbf7d0; background: #f0fdf4; color: var(--success); }
    #status.error   { border-color: #fecaca; background: #fef2f2; color: #dc2626; }

    #status a {
      font-family: 'Space Mono', monospace;
      font-size: 0.75rem;
      color: var(--accent2);
      text-decoration: none;
      word-break: break-all;
    }

    /* --- RIGHT PANEL --- */
    .right { display: flex; flex-direction: column; gap: 12px; }

    .panel-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .panel-title {
      font-family: 'Space Mono', monospace;
      font-size: 0.72rem;
      color: var(--muted);
      letter-spacing: 0.06em;
      text-transform: uppercase;
    }

    .count-badge {
      font-family: 'Space Mono', monospace;
      font-size: 0.65rem;
      background: var(--border);
      color: var(--muted);
      padding: 2px 7px;
      border-radius: 99px;
    }

    #search {
      width: 100%;
      padding: 8px 12px;
      font-family: 'DM Sans', sans-serif;
      font-size: 0.85rem;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      background: var(--surface);
      color: var(--accent);
      outline: none;
      transition: border-color 0.15s;
    }

    #search:focus { border-color: var(--accent2); }
    #search::placeholder { color: var(--muted); }

    #file-list {
      display: flex;
      flex-direction: column;
      gap: 6px;
      max-height: 60vh;
      overflow-y: auto;
      padding-right: 2px;
    }

    #file-list::-webkit-scrollbar { width: 4px; }
    #file-list::-webkit-scrollbar-track { background: transparent; }
    #file-list::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }

    .file-item {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 10px 12px;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      background: var(--surface);
      transition: border-color 0.12s;
    }

    .file-item:hover { border-color: #c8c5be; }

    .file-info { flex: 1; min-width: 0; }

    .file-name {
      font-size: 0.85rem;
      font-weight: 500;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      margin-bottom: 2px;
    }

    .file-meta {
      font-family: 'Space Mono', monospace;
      font-size: 0.68rem;
      color: var(--muted);
    }

    .file-actions { display: flex; gap: 4px; flex-shrink: 0; }

    .btn-small {
      font-family: 'Space Mono', monospace;
      font-size: 0.65rem;
      padding: 3px 7px;
      border: 1px solid var(--border);
      border-radius: 3px;
      background: var(--bg);
      cursor: pointer;
      color: var(--accent);
      text-decoration: none;
      transition: background 0.1s;
      display: inline-flex;
      align-items: center;
    }

    .btn-small:hover { background: var(--border); }
    .btn-small.copied { color: var(--success); border-color: #bbf7d0; }

    .empty {
      text-align: center;
      padding: 40px 0;
      color: var(--muted);
      font-size: 0.85rem;
    }

    .empty-icon { font-size: 1.5rem; margin-bottom: 8px; opacity: 0.3; }
  </style>
</head>
<body>
  <header>
    <span class="logo">drop<span>lify</span></span>
    <span class="badge">SELF-HOSTED</span>
  </header>

  <div class="layout">
    <div class="left">
      <h1>Glisse un fichier HTML<br><em>obtiens une URL.</em></h1>

      <div id="dropzone">
        <span class="drop-icon">⬆</span>
        <div class="drop-label">Glisse ici ou clique</div>
        <div class="drop-sub">.html · .htm</div>
      </div>
      <input type="file" id="file" accept=".html,.htm">

      <div id="status"></div>
    </div>

    <div class="right">
      <div class="panel-header">
        <span class="panel-title">Fichiers hébergés</span>
        <span class="count-badge" id="count">0</span>
      </div>
      <input type="text" id="search" placeholder="Filtrer par nom…">
      <div id="file-list">
        <div class="empty"><div class="empty-icon">📭</div>Aucun fichier encore</div>
      </div>
    </div>
  </div>

  <script>
    const dropzone = document.getElementById('dropzone');
    const input    = document.getElementById('file');
    const status   = document.getElementById('status');
    const fileList = document.getElementById('file-list');
    const countEl  = document.getElementById('count');
    const search   = document.getElementById('search');

    let allFiles = [];

    dropzone.addEventListener('click', () => input.click());
    dropzone.addEventListener('dragover', e => { e.preventDefault(); dropzone.classList.add('over'); });
    dropzone.addEventListener('dragleave', () => dropzone.classList.remove('over'));
    dropzone.addEventListener('drop', e => {
      e.preventDefault();
      dropzone.classList.remove('over');
      upload(e.dataTransfer.files[0]);
    });
    input.addEventListener('change', () => upload(input.files[0]));
    search.addEventListener('input', () => renderList(allFiles));

    function setStatus(type, html) {
      status.className = 'visible ' + type;
      status.innerHTML = html;
    }

    function fmtDate(ts) {
      const d = new Date(ts * 1000);
      return d.toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit', year: '2-digit' })
           + ' ' + d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
    }

    function renderList(files) {
      const q = search.value.trim().toLowerCase();
      const filtered = q ? files.filter(f => f.filename.toLowerCase().includes(q) || f.slug.includes(q)) : files;
      countEl.textContent = files.length;

      if (!filtered.length) {
        fileList.innerHTML = '<div class="empty"><div class="empty-icon">🔍</div>Aucun résultat</div>';
        return;
      }

      fileList.innerHTML = filtered.map(f => `
        <div class="file-item">
          <div class="file-info">
            <div class="file-name" title="${f.filename}">${f.filename}</div>
            <div class="file-meta">${f.slug} · ${fmtDate(f.uploaded_at)}</div>
          </div>
          <div class="file-actions">
            <a class="btn-small" href="${f.url}" target="_blank">ouvrir</a>
            <button class="btn-small" onclick="copyUrl('${f.url}', this)">copy</button>
          </div>
        </div>
      `).join('');
    }

    function copyUrl(url, btn) {
      navigator.clipboard.writeText(url);
      btn.textContent = '✓';
      btn.classList.add('copied');
      setTimeout(() => { btn.textContent = 'copy'; btn.classList.remove('copied'); }, 1500);
    }

    async function loadFiles() {
      try {
        const res = await fetch('/files');
        allFiles = await res.json();
        renderList(allFiles);
      } catch (e) {
        fileList.innerHTML = '<div class="empty">Erreur de chargement</div>';
      }
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
          setStatus('success',
            `<span>Hébergé :</span> <a href="${data.url}" target="_blank">${data.url}</a>
             <button class="btn-small" style="margin-left:auto" onclick="navigator.clipboard.writeText('${data.url}');this.textContent='✓'">copy</button>`
          );
          await loadFiles();
        } else {
          setStatus('error', `<span>Erreur : ${data.error || 'inconnue'}</span>`);
        }
      } catch (e) {
        setStatus('error', '<span>Erreur réseau</span>');
      }
    }

    loadFiles();
  </script>
</body>
</html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        path = self.path.strip("/")

        if path in ("", "index.html"):
            self._respond(200, "text/html", UPLOAD_PAGE.encode())
            return

        if path == "files":
            body = json.dumps(list_files()).encode()
            self._respond(200, "application/json", body)
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

        ct = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in ct:
            self._json(400, {"error": "multipart required"})
            return

        boundary = ""
        for part in ct.split(";"):
            part = part.strip()
            if part.startswith("boundary="):
                boundary = part[9:].strip('"')

        if not boundary:
            self._json(400, {"error": "boundary manquant"})
            return

        length = int(self.headers.get("Content-Length", 0))
        fields = parse_multipart(self.rfile, boundary, length)

        field = fields.get("file")
        if field is None:
            self._json(400, {"error": "champ 'file' manquant"})
            return

        slug = uuid.uuid4().hex[:8]
        dest = DATA_DIR / slug
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "index.html").write_bytes(field["data"])
        (dest / "meta.json").write_text(json.dumps({
            "filename": field["filename"],
            "uploaded_at": int(time.time()),
        }))

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
