"""arena-elo: MCP stdio server for Arena (ex-LMArena) Elo ratings.

No auth, no API key. Reads the public Hugging Face dataset
lmarena-ai/leaderboard-dataset (CC BY 4.0) through the public
datasets-server API. Ratings are Bradley-Terry fitted, shown on the Arena
Elo scale with 95% confidence intervals.

Boards are cached on disk for 6h, so a cold call costs a few HTTP pages
and warm calls are instant. History is appended locally each time a new
board snapshot is seen, since the upstream "full" split (1.1M rows for
text) is far too large to page over anonymously.

Protocol: JSON-RPC 2.0 over stdio, one object per line. stdout carries
protocol traffic only; logs go to stderr.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DATASET = "lmarena-ai/leaderboard-dataset"
BASE = "https://datasets-server.huggingface.co"
UA = "hermes-research"
HOME = os.path.expanduser("~")
CACHE_DIR = os.environ.get(
    "ARENA_ELO_CACHE", os.path.join(HOME, ".hermes", "cache", "arena-elo"))
LOG_PATH = os.path.join(CACHE_DIR, "history.jsonl")
INDEX_PATH = os.path.join(CACHE_DIR, "snapshots.json")
TTL = 6 * 3600
PAGE = 100
SPACING = 0.5
MAX_PAGES = 40

ARENAS = {
    "text": "text_style_control",
    "text_raw": "text",
    "text_factuality": "text_factuality",
    "vision": "vision_style_control",
    "vision_raw": "vision",
    "search": "search_style_control",
    "search_raw": "search",
    "search_factuality": "search_factuality",
    "document": "document_style_control",
    "document_raw": "document",
    "webdev": "webdev",
    "agent": "agent",
    "image": "text_to_image",
    "image_edit": "image_edit",
    "video": "text_to_video",
    "image_to_video": "image_to_video",
    "video_edit": "video_edit",
}
SCAN = ["text", "webdev", "vision", "search", "agent", "document"]

_mem = {}


def log(msg):
    print("[arena-elo] " + msg, file=sys.stderr, flush=True)


def _get(path, params, tries=4):
    url = BASE + path + "?" + urllib.parse.urlencode(params)
    last = ""
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=45) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            last = "HTTP %s on %s: %s" % (
                e.code, path, e.read()[:200].decode("utf-8", "replace"))
        except Exception as e:
            last = "%r on %s" % (e, path)
        time.sleep(1.5 * (i + 1))
    raise RuntimeError(last)


def _safe_name(cfg, cat):
    cat = (cat or "all").replace("/", "_").replace(" ", "_")
    return "%s__%s.json" % (cfg, cat)


def fetch_board(cfg, cat):
    """Page through one board and keep the requested category.

    Upstream rows are grouped by category and ordered by rank inside each
    block, so we stop as soon as a page brings no new row for the wanted
    category. Keeps a cold read at 5-6 pages instead of 112.
    """
    rows, offset = [], 0
    for page in range(MAX_PAGES):
        d = _get("/rows", {"dataset": DATASET, "config": cfg,
                           "split": "latest",
                           "offset": offset, "length": PAGE})
        batch = [r["row"] for r in d.get("rows", [])]
        if cat:
            kept = [r for r in batch
                    if str(r.get("category", "")).lower() == cat.lower()]
        else:
            kept = batch
        rows.extend(kept)
        offset += len(batch)
        if page and not kept:
            break
        if len(batch) < PAGE:
            break
        time.sleep(SPACING)
    if not rows:
        raise RuntimeError("empty board %s/%s" % (cfg, cat))
    return rows


def board(cfg, cat):
    """Disk-cached board; stale data is served rather than failing."""
    key = "%s|%s" % (cfg, cat or "all")
    hit = _mem.get(key)
    if hit and time.time() - hit["fetched_at"] < TTL:
        return hit
    path = os.path.join(CACHE_DIR, _safe_name(cfg, cat))
    disk = None
    if os.path.exists(path):
        try:
            with open(path) as f:
                disk = json.load(f)
        except ValueError:
            disk = None
    if disk and time.time() - disk.get("fetched_at", 0) < TTL:
        _mem[key] = disk
        return disk
    try:
        t0 = time.time()
        rows = fetch_board(cfg, cat)
        entry = {"fetched_at": time.time(), "config": cfg,
                 "category": cat or "all", "rows": rows, "stale": False}
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(path, "w") as f:
            json.dump(entry, f)
        log("refreshed %s in %.1fs (%d rows)"
            % (key, time.time() - t0, len(rows)))
        record_history(entry)
        _mem[key] = entry
        return entry
    except RuntimeError as e:
        if disk:
            log("refresh failed (%s), serving old cache" % (e,))
            disk = dict(disk)
            disk["stale"] = True
            disk["error"] = str(e)
            _mem[key] = disk
            return disk
        raise


# ------------------------------------------------------------- history

def _load_index():
    try:
        with open(INDEX_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def record_history(entry):
    """Append one published snapshot to the local history log, once."""
    rows = [r for r in entry["rows"] if r.get("rating") is not None]
    if not rows:
        return
    publish = str(rows[0].get("leaderboard_publish_date", ""))[:10]
    if not publish:
        return
    idx = _load_index()
    key = "%s|%s|%s" % (entry["config"], entry["category"], publish)
    if idx.get(key):
        return
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(LOG_PATH, "a") as f:
        for r in rows:
            f.write(json.dumps({
                "date": publish, "config": entry["config"],
                "category": entry["category"],
                "model": r.get("model_name"), "org": r.get("organization"),
                "elo": r.get("rating"), "lo": r.get("rating_lower"),
                "hi": r.get("rating_upper"), "votes": r.get("vote_count"),
                "rank": r.get("rank")}) + "\n")
    idx[key] = publish
    with open(INDEX_PATH, "w") as f:
        json.dump(idx, f)


def read_history(cfg, cat, needle):
    out = []
    try:
        with open(LOG_PATH) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("config") != cfg or r.get("category") != cat:
                    continue
                if needle in str(r.get("model", "")).lower():
                    out.append(r)
    except OSError:
        return []
    return out


# ---------------------------------------------------------------- tools

def elo(row):
    v = row.get("rating", row.get("score"))
    return None if v is None else float(v)


def fmt_metric(row):
    """Rating with its interval. Agent boards publish a score, not Elo."""
    if row.get("rating") is not None:
        s = "%.0f" % row["rating"]
        lo, hi = row.get("rating_lower"), row.get("rating_upper")
        if lo is not None and hi is not None:
            s += " (%.0f-%.0f)" % (float(lo), float(hi))
        return s
    if row.get("score") is not None:
        s = "%.3f" % row["score"]
        lo, hi = row.get("score_ci_lower"), row.get("score_ci_upper")
        if lo is not None and hi is not None:
            s += " (%.3f-%.3f)" % (float(lo), float(hi))
        return s
    return "n/a"


def fmt_votes(row):
    n = row.get("vote_count", row.get("observation_count"))
    return "%d" % int(n) if n is not None else "?"


def is_elo(rows):
    return any(r.get("rating") is not None for r in rows)


def resolve(arena):
    a = (arena or "text").strip().lower()
    if a in ARENAS:
        return ARENAS[a]
    if a in ARENAS.values():
        return a
    raise RuntimeError("unknown arena %r. Known: %s"
                       % (arena, ", ".join(sorted(ARENAS))))


def _stale_note(entry):
    if entry.get("stale"):
        age = (time.time() - entry["fetched_at"]) / 3600.0
        return ("> stale: upstream refresh failed, serving a %.1f h old "
                "cache (%s)" % (age, entry.get("error", "")))
    return ""


def arena_leaderboard(arena="text", category="overall", top=15):
    """Elo leaderboard for one Arena board, highest first.

    arena: text (style-controlled, default), text_raw, vision, vision_raw,
        webdev, agent, search, search_raw, document, document_raw, image,
        image_edit, video, image_to_video, video_edit, text_factuality,
        search_factuality.
    category: board sub-category, default "overall". Upstream also has
        chinese, coding, hard_prompts, creative_writing, webdev-html,
        image_to_webdev, diagram, captioning.
    top: how many models to return, 1-100.

    Each row carries Elo, the 95% interval, votes and rank. Elo is
    relative: a 100 point gap means the higher model wins about 64% of the
    head-to-head votes.
    """
    cfg = resolve(arena)
    cat = (category or "overall").strip()
    entry = board(cfg, cat)
    rows = [r for r in entry["rows"] if elo(r) is not None]
    if not rows:
        raise RuntimeError("no rated rows in %s/%s" % (cfg, cat))
    rows.sort(key=elo, reverse=True)
    n = max(1, min(int(top), 100))
    publish = str(rows[0].get("leaderboard_publish_date", "?"))[:10]
    elo_board = is_elo(rows)
    out = ["# Arena %s / %s, published %s" % (cfg, cat, publish),
           "%s. Source: %s (CC BY 4.0)."
           % ("Bradley-Terry fitted, Elo scale" if elo_board else
              "This board publishes a win-rate score, NOT Elo",
              DATASET)]
    note = _stale_note(entry)
    if note:
        out.append(note)
    label = "Elo (95% CI)" if elo_board else "Score (95% CI)"
    out += ["", "| # | Model | Org | %s | Votes |" % label,
            "|---|---|---|---|---|"]
    for i, r in enumerate(rows[:n], 1):
        out.append("| %d | %s | %s | %s | %s |"
                   % (i, r.get("model_name", "?"),
                      r.get("organization", "?"), fmt_metric(r),
                      fmt_votes(r)))
    if len(rows) > n:
        out += ["", "%d rated models on this board, top %d shown."
                % (len(rows), n)]
    return "\n".join(out)


def arena_find_model(query, arena="text"):
    """Find a model by name fragment and report its Elo wherever it ranks.

    query: case-insensitive fragment, e.g. "opus 5.5", "gemini 4", "fable".
    arena: one board name, or "all" to scan text, webdev, vision, search,
        agent and document (slow on a cold cache).

    Returns Elo, interval, rank, votes and board size per match. Every
    variant matches separately, so reasoning levels are distinct rows.
    """
    q = (query or "").strip().lower()
    if not q:
        raise RuntimeError("empty query")
    names = SCAN if (arena or "").strip().lower() == "all" else [arena]
    out, found = [], 0
    for name in names:
        cfg = resolve(name)
        try:
            entry = board(cfg, "overall")
        except RuntimeError as e:
            out.append("## %s: unavailable (%s)" % (cfg, e))
            continue
        rows = [r for r in entry["rows"] if elo(r) is not None]
        rows.sort(key=elo, reverse=True)
        hits = [r for r in rows if q in str(r.get("model_name", "")).lower()]
        if not hits:
            continue
        publish = str(rows[0].get("leaderboard_publish_date", "?"))[:10]
        out.append("## %s, published %s%s"
                   % (cfg, publish,
                      " (stale cache)" if entry.get("stale") else ""))
        for r in hits:
            rank = r.get("rank") or (rows.index(r) + 1)
            out.append("- **%s** [%s] rank %s/%d, %s %s"
                       % (r.get("model_name", "?"),
                          r.get("organization", "?"), rank, len(rows),
                          "Elo" if is_elo(rows) else "score",
                          fmt_metric(r)))
            found += 1
        out.append("")
    if not found:
        return "No model matching %r on %s." % (query, ", ".join(names))
    return "%d match(es) for %r\n\n%s" % (found, query, "\n".join(out))


def arena_history(model, arena="text", category="overall"):
    """Elo trajectory of a model from snapshots this server has recorded.

    model: case-insensitive name fragment. arena and category: as in
    arena_leaderboard. History is local by design: each upstream board
    snapshot is logged once when fetched, so the series starts the first
    time that board was read and grows as the board updates. Upstream
    keeps a full historical split, but text alone is 1.1M rows, too large
    to page over anonymously.
    """
    cfg = resolve(arena)
    cat = (category or "overall").strip()
    needle = (model or "").strip().lower()
    if not needle:
        raise RuntimeError("empty model")
    rs = read_history(cfg, cat, needle)
    if not rs:
        return ("No recorded history for %r in %s/%s yet. The series starts "
                "at the first board fetch by this server; call "
                "arena_leaderboard(arena=%r, category=%r) to record today's "
                "snapshot." % (model, cfg, cat, arena, cat))
    uniq = {}
    for r in rs:
        uniq.setdefault((r["date"], r["model"]), r)
    items = sorted(uniq.values(), key=lambda r: (r["date"], r["model"]))
    names = sorted({r["model"] for r in items})
    out = ["# Elo history: %s on %s/%s" % (" / ".join(names), cfg, cat),
           "%d recorded snapshot(s), oldest first." % len(items), "",
           "| Date | Model | Elo (95% CI) | Rank | Votes |",
           "|---|---|---|---|---|"]
    for r in items:
        ci = "%.0f" % r["elo"]
        if r.get("lo") is not None and r.get("hi") is not None:
            ci += " (%.0f-%.0f)" % (r["lo"], r["hi"])
        out.append("| %s | %s | %s | %s | %s |"
                   % (r["date"], r["model"], ci, r.get("rank", "?"),
                      int(r["votes"]) if r.get("votes") else "?"))
    return "\n".join(out)


def arena_arenas():
    """List the Arena boards available to this server, with row counts.

    Shows the dataset config, the friendly name accepted by the other
    tools, and how many rows the newest snapshot holds. No auth involved.
    """
    d = _get("/size", {"dataset": DATASET})["size"]
    latest = {}
    for s in d.get("splits", []):
        if s.get("split") == "latest":
            latest[s["config"]] = s.get("num_rows")
    rev = {}
    for friendly, cfg in ARENAS.items():
        rev.setdefault(cfg, friendly)
    out = ["# Arena boards, no auth", "",
           "| friendly name | config | rows (latest) |", "|---|---|---|"]
    for cfg in sorted(latest):
        out.append("| %s | %s | %s |"
                   % (rev.get(cfg, "-"), cfg, latest[cfg]))
    return "\n".join(out)


TOOLS = [
    ("arena_leaderboard", arena_leaderboard,
     {"arena": "string", "category": "string", "top": "integer"}),
    ("arena_find_model", arena_find_model,
     {"query": "string", "arena": "string"}),
    ("arena_history", arena_history,
     {"model": "string", "arena": "string", "category": "string"}),
    ("arena_arenas", arena_arenas, {}),
]

DEFAULTS = {"arena": "text", "category": "overall", "top": 15}


def schema_for(params):
    props, required = {}, []
    for p, t in params.items():
        props[p] = {"type": t}
        if p in DEFAULTS:
            props[p]["default"] = DEFAULTS[p]
        else:
            required.append(p)
    return {"type": "object", "properties": props, "required": required}


def tools_list():
    out = []
    for name, fn, params in TOOLS:
        out.append({"name": name,
                    "description": (fn.__doc__ or "").strip(),
                    "inputSchema": schema_for(params)})
    return out


def tools_call(name, args):
    for tname, fn, params in TOOLS:
        if tname == name:
            kwargs = {k: v for k, v in (args or {}).items() if k in params}
            return fn(**kwargs)
    raise RuntimeError("unknown tool %r" % name)


def reply(mid, result):
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def error(mid, code, message):
    return {"jsonrpc": "2.0", "id": mid,
            "error": {"code": code, "message": message}}


def handle(msg):
    method, mid = msg.get("method"), msg.get("id")
    params = msg.get("params") or {}
    if method == "initialize":
        return reply(mid, {
            "protocolVersion": params.get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "arena-elo", "version": "2.0.0"},
        })
    if method == "ping":
        return reply(mid, {})
    if method == "tools/list":
        return reply(mid, {"tools": tools_list()})
    if method == "tools/call":
        try:
            text = tools_call(params.get("name"), params.get("arguments"))
            return reply(mid, {"content": [{"type": "text", "text": text}],
                               "isError": False})
        except Exception as e:
            log("tool error: %r" % (e,))
            return reply(mid, {"content": [{"type": "text",
                                            "text": "error: %s" % e}],
                               "isError": True})
    if mid is None:
        return None
    return error(mid, -32601, "method not found: %s" % method)


def main():
    log("ready, dataset=%s, cache=%s" % (DATASET, CACHE_DIR))
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            log("bad json on stdin")
            continue
        try:
            out = handle(msg)
        except Exception as e:
            log("handler crash: %r" % (e,))
            out = error(msg.get("id"), -32603, str(e))
        if out is not None:
            sys.stdout.write(json.dumps(out) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
