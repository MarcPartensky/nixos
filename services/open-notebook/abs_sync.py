#!/usr/bin/env python3
"""Publish finished Open Notebook podcast episodes into Audiobookshelf.

Open Notebook writes each generated episode as one mp3 under its podcasts
folder. Audiobookshelf has no pull API, so this job pushes: it lists the
episodes through the Open Notebook API, uploads the ones it has not sent yet
into one podcast library item (the ABS "show"), then asks ABS to rescan.

State lives in a small JSON file keyed by Open Notebook episode id so a
restart never uploads twice; the fallback check is the list of filenames ABS
already knows in that item.
"""

from __future__ import annotations

import argparse
import json
import os
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid

DEFAULT_ON_API = "http://127.0.0.1:9601"
DEFAULT_ABS_URL = "http://127.0.0.1:8000"
DEFAULT_PODCASTS_ROOT = "/var/lib/open-notebook/data/podcasts"
DEFAULT_STATE = "/var/lib/hermes/.hermes/state/on-abs-sync.json"


def http_json(url, token=None, method="GET", payload=None, timeout=60):
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode()
        return json.loads(body) if body else None


def slugify(name: str) -> str:
    """ASCII, no comma, no quote: ABS and curl both trip on those."""
    text = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    keep = []
    for char in text:
        keep.append(char if char.isalnum() or char in " ._-" else " ")
    cleaned = " ".join("".join(keep).split())
    return cleaned[:90] or "episode"


def upload_file(abs_url, token, library, folder, title, path, filename, timeout=600):
    """POST one file to /api/upload (one file per request, ABS requirement)."""
    boundary = "----hermes" + uuid.uuid4().hex
    parts = []

    def field(name, value):
        parts.append(
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                f"{value}\r\n"
            ).encode()
        )

    field("library", library)
    field("folder", folder)
    field("title", title)
    with open(path, "rb") as handle:
        audio = handle.read()
    parts.append(
        (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="files"; filename="{filename}"\r\n'
            "Content-Type: audio/mpeg\r\n\r\n"
        ).encode()
        + audio
        + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)
    request = urllib.request.Request(
        f"{abs_url}/api/upload",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status, response.read().decode(errors="replace")


def find_item(abs_url, token, library, title):
    """Return (item_id, set of episode filenames) for the ABS show, if it exists."""
    listing = http_json(
        f"{abs_url}/api/libraries/{library}/items?limit=200", token=token
    ) or {}
    for item in listing.get("results", []):
        metadata = item.get("media", {}).get("metadata", {})
        if metadata.get("title") != title:
            continue
        detail = http_json(f"{abs_url}/api/items/{item['id']}", token=token) or {}
        filenames = set()
        for episode in detail.get("media", {}).get("episodes", []) or []:
            name = (episode.get("audioFile") or {}).get("metadata", {}).get("filename")
            if name:
                filenames.add(name)
            if episode.get("title"):
                filenames.add(episode["title"])
        return item["id"], filenames
    return None, set()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Publish Open Notebook podcast episodes into Audiobookshelf"
    )
    parser.add_argument("--on-api", default=DEFAULT_ON_API)
    parser.add_argument("--abs-url", default=DEFAULT_ABS_URL)
    parser.add_argument("--api-key-file", default="/run/secrets/audiobookshelf_api_key")
    parser.add_argument("--library-id", required=True)
    parser.add_argument("--folder-id", required=True)
    parser.add_argument("--title", default="Open Notebook")
    parser.add_argument("--podcasts-root", default=DEFAULT_PODCASTS_ROOT)
    parser.add_argument("--state", default=DEFAULT_STATE)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    with open(args.api_key_file, encoding="utf-8") as handle:
        token = handle.read().strip()

    state = {}
    if os.path.exists(args.state):
        with open(args.state, encoding="utf-8") as handle:
            state = json.load(handle)
    published = state.setdefault("episodes", {})

    episodes = http_json(f"{args.on_api}/api/podcasts/episodes") or []
    item_id, known_files = find_item(
        args.abs_url, token, args.library_id, args.title
    )
    print(
        f"{len(episodes)} episodes in Open Notebook, ABS item "
        f"{item_id or 'absent'} with {len(known_files)} files",
        flush=True,
    )

    uploaded = 0
    for episode in episodes:
        episode_id = episode.get("id") or ""
        relative = episode.get("audio_file")
        if not relative:
            print(f"[skip] {episode_id}: no audio yet", flush=True)
            continue
        if episode_id in published:
            continue
        path = os.path.join(args.podcasts_root, relative)
        if not os.path.exists(path):
            print(f"[warn] {episode_id}: missing file {path}", flush=True)
            continue
        created = (episode.get("created") or "")[:10]
        filename = f"{created} {slugify(episode.get('name') or 'episode')}.mp3"
        if filename in known_files:
            print(f"[skip] {episode_id}: already in ABS as {filename}", flush=True)
            published[episode_id] = {"file": filename, "note": "seen in ABS"}
            continue
        if args.dry_run:
            print(f"[dry-run] would upload {path} as {filename}", flush=True)
            continue
        try:
            status, body = upload_file(
                args.abs_url, token, args.library_id, args.folder_id, args.title,
                path, filename,
            )
        except urllib.error.HTTPError as exc:
            print(f"[KO] {episode_id}: HTTP {exc.code} {exc.read()[:200]!r}", flush=True)
            continue
        print(f"[ok] {episode_id}: {filename} (HTTP {status})", flush=True)
        published[episode_id] = {"file": filename}
        known_files.add(filename)
        uploaded += 1

    if not args.dry_run and (uploaded or not item_id):
        scan = urllib.request.Request(
            f"{args.abs_url}/api/libraries/{args.library_id}/scan",
            data=b"{}",
            method="POST",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(scan, timeout=120) as response:
            print(f"scan triggered: HTTP {response.status}", flush=True)

    if not args.dry_run:
        os.makedirs(os.path.dirname(args.state), exist_ok=True)
        tmp = args.state + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=1, ensure_ascii=False)
        os.replace(tmp, args.state)

    final_item, final_files = find_item(args.abs_url, token, args.library_id, args.title)
    print(
        f"done: uploaded {uploaded}, ABS item {final_item or 'pending scan'} "
        f"with {len(final_files)} known files",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
