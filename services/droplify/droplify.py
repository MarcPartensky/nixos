#!/usr/bin/env python3
# droplify.py - stdlib only, Python 3.13+ compatible

import http.server
import os
import uuid
import json
import time
import shutil
from pathlib import Path

DATA_DIR = Path(os.environ.get("DATA_DIR", "/var/lib/droplify"))
BASE_URL  = os.environ.get("BASE_URL", "http://localhost:8080")
PORT      = int(os.environ.get("PORT", "8080"))

FAVICON_SVG = """<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 96 96'><rect width='96' height='96' rx='22' fill='%236366f1'/><path d='M48 18C48 18 28 42 28 56C28 67.6 37.4 77 49 77C60.6 77 70 67.6 70 56C70 42 50 18 48 18Z' fill='white' opacity='.95'/><line x1='48' y1='64' x2='48' y2='38' stroke='%236366f1' stroke-width='4.5' stroke-linecap='round'/><polyline points='40,47 48,37 56,47' fill='none' stroke='%236366f1' stroke-width='4.5' stroke-linecap='round' stroke-linejoin='round'/></svg>"""

OG_IMAGE_SVG = """<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1200 630'><rect width='1200' height='630' fill='%23fafaf8'/><rect x='504' y='219' width='192' height='192' rx='44' fill='%236366f1'/><path d='M600 255C600 255 564 303 564 327C564 348.2 580.8 366 602 366C623.2 366 640 348.2 640 327C640 303 602 255 600 255Z' fill='white' opacity='.95'/><line x1='600' y1='350' x2='600' y2='298' stroke='%236366f1' stroke-width='9' stroke-linecap='round'/><polyline points='584,314 600,296 616,314' fill='none' stroke='%236366f1' stroke-width='9' stroke-linecap='round' stroke-linejoin='round'/><text x='600' y='462' font-family='monospace' font-size='64' font-weight='700' fill='%231a1a1a' text-anchor='middle' letter-spacing='-1'>drop</text><text x='756' y='462' font-family='monospace' font-size='64' font-weight='700' fill='%236366f1' text-anchor='start' letter-spacing='-1'>lify</text></svg>"""


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
            fields[name] = {"data": body, "filename": filename or ""}
    return fields


def read_meta(slug_dir: Path) -> dict:
    meta_path = slug_dir / "meta.json"
    if meta_path.exists():
        try:
            return json.loads(meta_path.read_text())
        except Exception:
            pass
    return {}


def write_meta(slug_dir: Path, meta: dict):
    (slug_dir / "meta.json").write_text(json.dumps(meta))


def list_files():
    entries = []
    if not DATA_DIR.exists():
        return entries
    for slug_dir in sorted(DATA_DIR.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
        if not slug_dir.is_dir():
            continue
        if not (slug_dir / "index.html").exists():
            continue
        meta = read_meta(slug_dir)
        entries.append({
            "slug": slug_dir.name,
            "url": f"{BASE_URL}/{slug_dir.name}",
            "name": meta.get("name", meta.get("filename", slug_dir.name)),
            "uploaded_at": meta.get("uploaded_at", int(slug_dir.stat().st_mtime)),
        })
    return entries


UPLOAD_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>droplify</title>
  <meta name="description" content="Self-hosted HTML file hosting. Drop a file, get a URL.">

  <!-- Open Graph / bookmark preview -->
  <meta property="og:type" content="website">
  <meta property="og:title" content="droplify">
  <meta property="og:description" content="Self-hosted HTML file hosting. Drop a file, get a URL.">
  <meta property="og:image" content="/og-image.svg">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:image" content="/og-image.svg">

  <!-- Favicon -->
  <link rel="icon" type="image/svg+xml" href="/favicon.svg">

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
      --danger: #dc2626;
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
      padding: 16px 28px;
      display: flex;
      align-items: center;
      gap: 10px;
      border-bottom: 1px solid var(--border);
      background: var(--bg);
      z-index: 10;
    }

    .logo-icon {
      width: 28px; height: 28px;
      flex-shrink: 0;
    }

    .logo {
      font-family: 'Space Mono', monospace;
      font-size: 0.92rem;
      font-weight: 700;
      letter-spacing: -0.02em;
    }

    .logo span { color: var(--accent2); }

    .badge {
      font-family: 'Space Mono', monospace;
      font-size: 0.63rem;
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
      grid-template-columns: 320px 1fr;
      gap: 32px;
      align-items: start;
    }

    @media (max-width: 700px) { .layout { grid-template-columns: 1fr; } }

    .left { display: flex; flex-direction: column; gap: 14px; }

    h1 { font-size: 1.35rem; font-weight: 500; letter-spacing: -0.03em; line-height: 1.25; }
    h1 em { font-style: normal; color: var(--muted); }

    #dropzone {
      border: 1.5px dashed var(--border);
      border-radius: var(--radius);
      padding: 36px 24px;
      text-align: center;
      cursor: pointer;
      transition: border-color 0.15s, background 0.15s;
      background: var(--surface);
      user-select: none;
    }

    #dropzone:hover, #dropzone.over { border-color: var(--accent2); background: #f5f5ff; }
    #dropzone.over { border-style: solid; }

    .drop-icon { font-size: 1.8rem; margin-bottom: 10px; display: block; opacity: 0.4; }
    .drop-label { font-size: 0.88rem; font-weight: 500; margin-bottom: 4px; }
    .drop-sub { font-size: 0.76rem; color: var(--muted); }

    input[type=file] { display: none; }

    #confirm-panel {
      display: none;
      flex-direction: column;
      gap: 10px;
      padding: 14px;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      background: var(--surface);
    }

    #confirm-panel.visible { display: flex; }

    .confirm-file { font-size: 0.8rem; color: var(--muted); display: flex; align-items: center; gap: 6px; }
    .confirm-file strong { color: var(--accent); font-weight: 500; }

    .name-row { display: flex; gap: 8px; }

    .name-input {
      flex: 1;
      padding: 7px 10px;
      font-family: 'DM Sans', sans-serif;
      font-size: 0.84rem;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      background: var(--bg);
      color: var(--accent);
      outline: none;
      transition: border-color 0.15s;
    }

    .name-input:focus { border-color: var(--accent2); }

    .btn-upload {
      padding: 7px 14px;
      font-family: 'Space Mono', monospace;
      font-size: 0.7rem;
      background: var(--accent2);
      color: #fff;
      border: none;
      border-radius: var(--radius);
      cursor: pointer;
      transition: opacity 0.15s;
      white-space: nowrap;
    }

    .btn-upload:hover { opacity: 0.85; }

    .btn-cancel-upload {
      padding: 7px 10px;
      font-family: 'Space Mono', monospace;
      font-size: 0.7rem;
      background: transparent;
      color: var(--muted);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      cursor: pointer;
    }

    .btn-cancel-upload:hover { color: var(--accent); }

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
    #status.error   { border-color: #fecaca; background: #fef2f2; color: var(--danger); }
    #status a { font-family: 'Space Mono', monospace; font-size: 0.74rem; color: var(--accent2); text-decoration: none; word-break: break-all; }

    .right { display: flex; flex-direction: column; gap: 12px; }

    .panel-header { display: flex; align-items: center; justify-content: space-between; }

    .panel-title { font-family: 'Space Mono', monospace; font-size: 0.7rem; color: var(--muted); letter-spacing: 0.06em; text-transform: uppercase; }

    .count-badge { font-family: 'Space Mono', monospace; font-size: 0.63rem; background: var(--border); color: var(--muted); padding: 2px 7px; border-radius: 99px; }

    #search {
      width: 100%;
      padding: 8px 12px;
      font-family: 'DM Sans', sans-serif;
      font-size: 0.84rem;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      background: var(--surface);
      color: var(--accent);
      outline: none;
      transition: border-color 0.15s;
    }

    #search:focus { border-color: var(--accent2); }
    #search::placeholder { color: var(--muted); }

    #file-list { display: flex; flex-direction: column; gap: 6px; max-height: 62vh; overflow-y: auto; padding-right: 2px; }
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

    .file-name-display {
      font-size: 0.84rem;
      font-weight: 500;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      margin-bottom: 2px;
    }

    .file-name-edit {
      display: none;
      width: 100%;
      padding: 3px 6px;
      font-family: 'DM Sans', sans-serif;
      font-size: 0.84rem;
      font-weight: 500;
      border: 1px solid var(--accent2);
      border-radius: 3px;
      background: var(--bg);
      color: var(--accent);
      outline: none;
      margin-bottom: 2px;
    }

    .file-item.renaming .file-name-display { display: none; }
    .file-item.renaming .file-name-edit { display: block; }

    .file-meta { font-family: 'Space Mono', monospace; font-size: 0.66rem; color: var(--muted); }

    .file-actions { display: flex; gap: 4px; flex-shrink: 0; flex-wrap: wrap; justify-content: flex-end; }

    .btn-small {
      font-family: 'Space Mono', monospace;
      font-size: 0.63rem;
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
    .btn-small.rename-ok { color: var(--success); border-color: #bbf7d0; background: #f0fdf4; }
    .btn-small.cancel-r { color: var(--muted); }

    .btn-delete {
      color: var(--danger);
      border-color: #fecaca;
    }

    .btn-delete:hover { background: #fef2f2; }

    .btn-delete.confirming {
      background: var(--danger);
      color: white;
      border-color: var(--danger);
    }

    .empty { text-align: center; padding: 40px 0; color: var(--muted); font-size: 0.84rem; }
    .empty-icon { font-size: 1.4rem; margin-bottom: 8px; opacity: 0.3; }
  </style>
</head>
<body>
  <header>
    <svg class="logo-icon" viewBox="0 0 96 96" xmlns="http://www.w3.org/2000/svg">
      <rect width="96" height="96" rx="22" fill="#6366f1"/>
      <path d="M48 18C48 18 28 42 28 56C28 67.6 37.4 77 49 77C60.6 77 70 67.6 70 56C70 42 50 18 48 18Z" fill="white" opacity=".95"/>
      <line x1="48" y1="64" x2="48" y2="38" stroke="#6366f1" stroke-width="4.5" stroke-linecap="round"/>
      <polyline points="40,47 48,37 56,47" fill="none" stroke="#6366f1" stroke-width="4.5" stroke-linecap="round" stroke-linejoin="round"/>
    </svg>
    <span class="logo">drop<span>lify</span></span>
    <span class="badge">SELF-HOSTED</span>
  </header>

  <div class="layout">
    <div class="left">
      <h1>Drop an HTML file,<br><em>get a URL.</em></h1>

      <div id="dropzone">
        <span class="drop-icon">⬆</span>
        <div class="drop-label">Drop here or click to browse</div>
        <div class="drop-sub">.html &middot; .htm</div>
      </div>
      <input type="file" id="file" accept=".html,.htm">

      <div id="confirm-panel">
        <div class="confirm-file">&#128196; <strong id="confirm-filename"></strong></div>
        <div class="name-row">
          <input type="text" class="name-input" id="upload-name" placeholder="Display name&hellip;">
          <button class="btn-upload" id="btn-confirm-upload">Host it</button>
          <button class="btn-cancel-upload" id="btn-cancel-upload">&#x2715;</button>
        </div>
      </div>

      <div id="status"></div>
    </div>

    <div class="right">
      <div class="panel-header">
        <span class="panel-title">Hosted files</span>
        <span class="count-badge" id="count">0</span>
      </div>
      <input type="text" id="search" placeholder="Filter by name&hellip;">
      <div id="file-list">
        <div class="empty"><div class="empty-icon">&#128217;</div>No files yet</div>
      </div>
    </div>
  </div>

  <script>
    const dropzone      = document.getElementById('dropzone');
    const fileInput     = document.getElementById('file');
    const status        = document.getElementById('status');
    const fileList      = document.getElementById('file-list');
    const countEl       = document.getElementById('count');
    const search        = document.getElementById('search');
    const confirmPanel  = document.getElementById('confirm-panel');
    const confirmName   = document.getElementById('confirm-filename');
    const uploadName    = document.getElementById('upload-name');
    const btnConfirm    = document.getElementById('btn-confirm-upload');
    const btnCancel     = document.getElementById('btn-cancel-upload');

    let allFiles    = [];
    let pendingFile = null;

    dropzone.addEventListener('click', () => fileInput.click());
    dropzone.addEventListener('dragover', e => { e.preventDefault(); dropzone.classList.add('over'); });
    dropzone.addEventListener('dragleave', () => dropzone.classList.remove('over'));
    dropzone.addEventListener('drop', e => { e.preventDefault(); dropzone.classList.remove('over'); stage(e.dataTransfer.files[0]); });
    fileInput.addEventListener('change', () => stage(fileInput.files[0]));

    function stage(file) {
      if (!file) return;
      pendingFile = file;
      confirmName.textContent = file.name;
      uploadName.value = file.name.replace(/\.html?$/i, '');
      confirmPanel.classList.add('visible');
      uploadName.focus();
      uploadName.select();
      setStatus('', '');
    }

    function clearStage() {
      pendingFile = null;
      confirmPanel.classList.remove('visible');
      fileInput.value = '';
    }

    btnCancel.addEventListener('click', clearStage);
    uploadName.addEventListener('keydown', e => { if (e.key === 'Enter') btnConfirm.click(); if (e.key === 'Escape') clearStage(); });
    btnConfirm.addEventListener('click', () => { if (pendingFile) upload(pendingFile, uploadName.value.trim() || pendingFile.name); });

    function setStatus(type, html) {
      if (!type) { status.className = ''; status.innerHTML = ''; return; }
      status.className = 'visible ' + type;
      status.innerHTML = html;
    }

    function fmtDate(ts) {
      const d = new Date(ts * 1000);
      return d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: '2-digit' })
           + ' ' + d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
    }

    function renderList(files) {
      const q = search.value.trim().toLowerCase();
      const filtered = q ? files.filter(f => f.name.toLowerCase().includes(q) || f.slug.includes(q)) : files;
      countEl.textContent = files.length;

      if (!filtered.length) {
        fileList.innerHTML = files.length
          ? '<div class="empty"><div class="empty-icon">&#128269;</div>No results</div>'
          : '<div class="empty"><div class="empty-icon">&#128217;</div>No files yet</div>';
        return;
      }

      fileList.innerHTML = '';
      filtered.forEach(f => {
        const item = document.createElement('div');
        item.className = 'file-item';
        item.dataset.slug = f.slug;
        item.innerHTML = `
          <div class="file-info">
            <div class="file-name-display" title="${f.name}">${f.name}</div>
            <input type="text" class="file-name-edit" value="${f.name}">
            <div class="file-meta">${f.slug} &middot; ${fmtDate(f.uploaded_at)}</div>
          </div>
          <div class="file-actions">
            <a class="btn-small" href="${f.url}" target="_blank">open</a>
            <button class="btn-small btn-copy" data-url="${f.url}">copy</button>
            <button class="btn-small btn-rename-toggle">rename</button>
            <button class="btn-small rename-ok" style="display:none">&#10003;</button>
            <button class="btn-small cancel-r btn-rename-cancel" style="display:none">&#x2715;</button>
            <button class="btn-small btn-delete" data-slug="${f.slug}">delete</button>
          </div>
        `;

        const editInput  = item.querySelector('.file-name-edit');
        const display    = item.querySelector('.file-name-display');
        const btnToggle  = item.querySelector('.btn-rename-toggle');
        const btnOk      = item.querySelector('.rename-ok');
        const btnCancelR = item.querySelector('.btn-rename-cancel');
        const btnCopy    = item.querySelector('.btn-copy');
        const btnDel     = item.querySelector('.btn-delete');

        // copy
        btnCopy.addEventListener('click', () => {
          navigator.clipboard.writeText(f.url);
          btnCopy.textContent = '\u2713';
          btnCopy.classList.add('copied');
          setTimeout(() => { btnCopy.textContent = 'copy'; btnCopy.classList.remove('copied'); }, 1500);
        });

        // rename
        function startRename() {
          item.classList.add('renaming');
          btnToggle.style.display = 'none';
          btnOk.style.display = 'inline-flex';
          btnCancelR.style.display = 'inline-flex';
          btnDel.style.display = 'none';
          editInput.focus();
          editInput.select();
        }

        function cancelRename() {
          item.classList.remove('renaming');
          editInput.value = display.textContent;
          btnToggle.style.display = 'inline-flex';
          btnOk.style.display = 'none';
          btnCancelR.style.display = 'none';
          btnDel.style.display = 'inline-flex';
        }

        async function confirmRename() {
          const newName = editInput.value.trim();
          if (!newName || newName === display.textContent) { cancelRename(); return; }
          try {
            const res = await fetch('/rename', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ slug: f.slug, name: newName }),
            });
            const data = await res.json();
            if (data.ok) { display.textContent = newName; f.name = newName; }
          } catch (e) {}
          cancelRename();
        }

        btnToggle.addEventListener('click', startRename);
        btnOk.addEventListener('click', confirmRename);
        btnCancelR.addEventListener('click', cancelRename);
        editInput.addEventListener('keydown', e => { if (e.key === 'Enter') confirmRename(); if (e.key === 'Escape') cancelRename(); });

        // delete (two-click confirmation)
        let deleteTimer = null;

        btnDel.addEventListener('click', async () => {
          if (!btnDel.classList.contains('confirming')) {
            btnDel.classList.add('confirming');
            btnDel.textContent = 'sure?';
            deleteTimer = setTimeout(() => {
              btnDel.classList.remove('confirming');
              btnDel.textContent = 'delete';
            }, 2500);
            return;
          }
          clearTimeout(deleteTimer);
          try {
            const res = await fetch('/delete', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ slug: f.slug }),
            });
            const data = await res.json();
            if (data.ok) {
              item.style.opacity = '0';
              item.style.transition = 'opacity 0.2s';
              setTimeout(() => {
                allFiles = allFiles.filter(x => x.slug !== f.slug);
                renderList(allFiles);
              }, 200);
            }
          } catch (e) {}
        });

        fileList.appendChild(item);
      });
    }

    search.addEventListener('input', () => renderList(allFiles));

    async function loadFiles() {
      try {
        const res = await fetch('/files');
        allFiles = await res.json();
        renderList(allFiles);
      } catch (e) {
        fileList.innerHTML = '<div class="empty">Failed to load files</div>';
      }
    }

    async function upload(file, name) {
      setStatus('loading', '<span>Uploading&hellip;</span>');
      clearStage();
      const fd = new FormData();
      fd.append('file', file);
      fd.append('name', name);
      try {
        const res  = await fetch('/upload', { method: 'POST', body: fd });
        const data = await res.json();
        if (data.url) {
          setStatus('success',
            `<span>Hosted:</span> <a href="${data.url}" target="_blank">${data.url}</a>
             <button class="btn-small" style="margin-left:auto" onclick="navigator.clipboard.writeText('${data.url}');this.textContent='\u2713'">copy</button>`
          );
          await loadFiles();
        } else {
          setStatus('error', `<span>Error: ${data.error || 'unknown'}</span>`);
        }
      } catch (e) {
        setStatus('error', '<span>Network error</span>');
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

        if path == "favicon.svg":
            self._respond(200, "image/svg+xml", FAVICON_SVG.encode())
            return

        if path == "og-image.svg":
            self._respond(200, "image/svg+xml", OG_IMAGE_SVG.encode())
            return

        if path == "files":
            self._respond(200, "application/json", json.dumps(list_files()).encode())
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
        if self.path == "/upload":
            self._handle_upload()
        elif self.path == "/rename":
            self._handle_rename()
        elif self.path == "/delete":
            self._handle_delete()
        else:
            self._respond(404, "text/plain", b"Not found")

    def _handle_upload(self):
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
            self._json(400, {"error": "missing boundary"})
            return

        length = int(self.headers.get("Content-Length", 0))
        fields = parse_multipart(self.rfile, boundary, length)

        field = fields.get("file")
        if field is None:
            self._json(400, {"error": "missing 'file' field"})
            return

        name_field = fields.get("name")
        name = name_field["data"].decode("utf-8", errors="replace").strip() if name_field else ""
        if not name:
            name = field["filename"] or "untitled"

        slug = uuid.uuid4().hex[:8]
        dest = DATA_DIR / slug
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "index.html").write_bytes(field["data"])
        write_meta(dest, {
            "name": name,
            "filename": field["filename"],
            "uploaded_at": int(time.time()),
        })

        self._json(200, {"url": f"{BASE_URL}/{slug}", "slug": slug})

    def _handle_rename(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            data = json.loads(self.rfile.read(length))
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return

        slug = data.get("slug", "").strip()
        name = data.get("name", "").strip()

        if not slug or not name:
            self._json(400, {"error": "slug and name required"})
            return

        slug_dir = DATA_DIR / slug
        if not slug_dir.is_dir():
            self._json(404, {"error": "slug not found"})
            return

        meta = read_meta(slug_dir)
        meta["name"] = name
        write_meta(slug_dir, meta)
        self._json(200, {"ok": True})

    def _handle_delete(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            data = json.loads(self.rfile.read(length))
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return

        slug = data.get("slug", "").strip()
        if not slug:
            self._json(400, {"error": "slug required"})
            return

        # safety: slug must be hex only (prevents path traversal)
        if not all(c in "0123456789abcdef" for c in slug):
            self._json(400, {"error": "invalid slug"})
            return

        slug_dir = DATA_DIR / slug
        if not slug_dir.is_dir():
            self._json(404, {"error": "slug not found"})
            return

        shutil.rmtree(slug_dir)
        self._json(200, {"ok": True})

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
    print(f"droplify running at {BASE_URL} (port {PORT})")
    server.serve_forever()
