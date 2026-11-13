"""MCP server: username and email enumeration across social networks.

Multi-engine (sherlock, maigret, socialscan) with a negative-control pass
that drops sites which "find" a username that cannot exist (the main source
of false positives in Sherlock-style tools).

Speaks MCP over stdio: one JSON-RPC message per line, nothing else on stdout.
"""

import csv
import glob
import json
import os
import random
import re
import shutil
import string
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

PROTOCOL_VERSION = "2025-06-18"
SERVER_NAME = "username-recon"
SERVER_VERSION = "1.0.0"

STATE = os.environ.get(
    "SHERLOCK_MCP_STATE", "/var/lib/hermes/.hermes/cache/username-recon"
)
TTL_HOURS = float(os.environ.get("SHERLOCK_MCP_CONTROL_TTL", "72"))
USERNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")

CLAIMED = {"claimed", "found", "taken", "exists"}
UNKNOWN = {"unknown", "illegal", "rate-limit", "blocked", "suspended"}


def log(msg):
    sys.stderr.write("username-recon: %s\n" % msg)
    sys.stderr.flush()


def state_dir(*parts):
    p = os.path.join(STATE, *parts)
    return p


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    return path


# --------------------------------------------------------------------------
# engines
# --------------------------------------------------------------------------


def which(env_var, default):
    cand = os.environ.get(env_var) or shutil.which(default)
    return cand if cand else None


def prefix_of(binary):
    real = os.path.realpath(binary)
    return os.path.dirname(os.path.dirname(real))


class Engine:
    name = "?"
    env_var = ""
    default_bin = ""
    kind = "sites"
    caps = {}

    def __init__(self):
        self.bin = which(self.env_var, self.default_bin)
        self.data_file = self.find_data() if self.bin else None

    def find_data(self):
        return None

    @property
    def available(self):
        return bool(self.bin)

    def version(self):
        if not self.bin:
            return None
        try:
            out = subprocess.run(
                [self.bin, "--version"],
                capture_output=True,
                text=True,
                timeout=60,
            )
            first = (out.stdout or out.stderr).strip().splitlines()
            return first[0].strip() if first else None
        except Exception as exc:  # noqa: BLE001
            return "error: %s" % exc

    def site_names(self):
        return []

    def site_entries(self):
        return {}

    def run(self, query, sites=None, timeout=45, proxy=None, nsfw=False,
            recursion=False):
        raise NotImplementedError


class Sherlock(Engine):
    name = "sherlock"
    env_var = "SHERLOCK_BIN"
    default_bin = "sherlock"
    caps = {
        "sites": 414,
        "profile_parsing": False,
        "email_search": False,
        "json_report": "csv",
        "proxy": True,
        "tor": True,
        "nsfw_toggle": True,
        "site_filter": True,
        "signup_api_probes": False,
    }

    def find_data(self):
        for pat in (
            "share/sherlock_project/resources/data.json",
            "lib/python3*/site-packages/sherlock_project/resources/data.json",
        ):
            hit = glob.glob(os.path.join(prefix_of(self.bin), pat))
            if hit:
                return hit[0]
        return None

    def site_entries(self):
        if not self.data_file or not os.path.exists(self.data_file):
            return {}
        try:
            with open(self.data_file) as fh:
                raw = json.load(fh)
        except Exception:  # noqa: BLE001
            return {}
        return {k: v for k, v in raw.items() if isinstance(v, dict)}

    def run(self, query, sites=None, timeout=45, proxy=None, nsfw=False,
            recursion=False):
        work = ensure_dir(
            os.path.join(STATE, "tmp", "sherlock-%d-%d" % (os.getpid(), time.time()))
        )
        cmd = [self.bin, query, "--csv", "--print-all", "--no-color",
               "--timeout", str(timeout)]
        if nsfw:
            cmd.append("--nsfw")
        if proxy:
            cmd += ["--proxy", proxy]
        for site in sites or []:
            cmd += ["--site", site]
        proc = subprocess.run(cmd, cwd=work, capture_output=True, text=True,
                              timeout=max(120, timeout * 6))
        rows = []
        csv_path = os.path.join(work, "%s.csv" % query)
        if os.path.exists(csv_path):
            with open(csv_path, newline="") as fh:
                for row in csv.DictReader(fh):
                    rows.append(row)
        else:
            log("sherlock wrote no csv: %s" % (proc.stderr or "")[-400:])
        hits = {}
        claimed = 0
        for row in rows:
            exists = (row.get("exists") or "").strip().lower()
            if exists in CLAIMED:
                state = "claimed"
            elif exists in UNKNOWN:
                state = "unknown"
            else:
                state = "available"
            if state == "claimed":
                claimed += 1
            hits.setdefault(row.get("name") or "?", {
                "site": row.get("name") or "?",
                "state": state,
                "url": row.get("url_user"),
                "http_status": row.get("http_status"),
            })
        return {"engine": self.name, "probed": len(rows), "hits": claimed,
                "results": hits, "error": None}


class Maigret(Engine):
    name = "maigret"
    env_var = "MAIGRET_BIN"
    default_bin = "maigret"
    caps = {
        "sites": 3155,
        "profile_parsing": True,
        "email_search": False,
        "json_report": "json",
        "proxy": True,
        "tor": True,
        "nsfw_toggle": False,
        "site_filter": True,
        "signup_api_probes": False,
    }
    PROFILE_KEYS = (
        "name", "fullname", "bio", "location", "avatar", "followers",
        "rank", "site_name", "username",
    )

    def find_data(self):
        pat = "lib/python3*/site-packages/maigret/resources/data.json"
        hit = glob.glob(os.path.join(prefix_of(self.bin), pat))
        return hit[0] if hit else None

    def db_path(self):
        """A writable copy of maigret's site DB.

        maigret rewrites its DB on exit; the store copy is read-only and the
        process otherwise dies with PermissionError after writing reports.
        """
        target = state_dir("maigret-db.json")
        if not os.path.exists(target) and self.data_file:
            ensure_dir(STATE)
            shutil.copyfile(self.data_file, target)
            os.chmod(target, 0o644)
        return target if os.path.exists(target) else None

    def site_entries(self):
        db = self.db_path() or self.data_file
        if not db or not os.path.exists(db):
            return {}
        try:
            with open(db) as fh:
                raw = json.load(fh)
        except Exception:  # noqa: BLE001
            return {}
        sites = raw.get("sites", raw)
        return {k: v for k, v in sites.items() if isinstance(v, dict)}

    def run(self, query, sites=None, timeout=45, proxy=None, nsfw=False,
            recursion=False):
        work = ensure_dir(
            os.path.join(STATE, "tmp", "maigret-%d-%d" % (os.getpid(), time.time()))
        )
        cmd = [self.bin, query, "--no-progressbar", "--no-color", "-J", "simple",
               "-fo", work, "--timeout", str(timeout)]
        db = self.db_path()
        if db:
            cmd += ["--db", db]
        if not recursion:
            cmd.append("--no-recursion")
        if proxy:
            cmd += ["--proxy", proxy]
        for site in sites or []:
            cmd += ["--site", site]
        proc = subprocess.run(cmd, cwd=work, capture_output=True, text=True,
                              timeout=max(180, timeout * 8))
        report = os.path.join(work, "report_%s_simple.json" % query)
        hits = {}
        err = None
        if os.path.exists(report):
            with open(report) as fh:
                data = json.load(fh)
            for site, entry in data.items():
                status = entry.get("status") or {}
                raw_state = str(status.get("status") or "").strip().lower()
                if raw_state in CLAIMED:
                    state = "claimed"
                elif raw_state in UNKNOWN:
                    state = "unknown"
                else:
                    state = "available"
                profile = {}
                for key in self.PROFILE_KEYS:
                    val = status.get(key) or entry.get(key)
                    if val and key != "username":
                        profile[key] = val
                if status.get("ids_data"):
                    profile["ids"] = status["ids_data"]
                hits[site] = {
                    "site": site,
                    "state": state,
                    "url": entry.get("url_user") or status.get("url"),
                    "profile": profile,
                }
        else:
            err = (proc.stderr or "")[-400:] or "no report produced"
            log("maigret produced no report: %s" % err)
        claimed = sum(1 for v in hits.values() if v["state"] == "claimed")
        return {"engine": self.name, "probed": None, "hits": claimed,
                "reported": len(data) if os.path.exists(report) else 0,
                "results": hits, "error": err}


class Socialscan(Engine):
    name = "socialscan"
    env_var = "SOCIALSCAN_BIN"
    default_bin = "socialscan"
    kind = "platforms"
    caps = {
        "sites": 11,
        "profile_parsing": False,
        "email_search": True,
        "json_report": "json",
        "proxy": False,
        "tor": False,
        "nsfw_toggle": False,
        "site_filter": True,
        "signup_api_probes": True,
    }

    def run(self, query, sites=None, timeout=45, proxy=None, nsfw=False,
            recursion=False):
        work = ensure_dir(
            os.path.join(STATE, "tmp", "socialscan-%d-%d" % (os.getpid(), time.time()))
        )
        out = os.path.join(work, "out.json")
        cmd = [self.bin, query, "--json", out]
        if sites:
            cmd.append("--platforms")
            cmd += list(sites)
        proc = subprocess.run(cmd, cwd=work, capture_output=True, text=True,
                              timeout=max(120, timeout * 4))
        hits = {}
        err = None
        probed = 0
        if os.path.exists(out) and os.path.getsize(out) > 2:
            with open(out) as fh:
                data = json.load(fh)
            for entry in (data.get(query) or []):
                probed += 1
                ok = str(entry.get("success", "")).lower() == "true"
                free = str(entry.get("available", "")).lower() == "true"
                if not ok:
                    state = "unknown"
                elif free:
                    state = "available"
                else:
                    state = "claimed"
                hits[entry.get("platform") or "?"] = {
                    "site": entry.get("platform") or "?",
                    "state": state,
                    "url": None,
                    "note": entry.get("message") or "",
                }
        else:
            err = (proc.stderr or "")[-300:] or "no json produced"
        claimed = sum(1 for v in hits.values() if v["state"] == "claimed")
        return {"engine": self.name, "probed": probed, "hits": claimed,
                "results": hits, "error": err}


ENGINES = {e.name: e for e in (Sherlock(), Maigret(), Socialscan())}


def available_engines(kind=None):
    out = []
    for name, eng in ENGINES.items():
        if kind and eng.kind != kind:
            continue
        if eng.available:
            out.append(name)
    return out


# --------------------------------------------------------------------------
# negative control
# --------------------------------------------------------------------------


def control_username():
    tail = "".join(random.choice(string.ascii_lowercase + string.digits)
                   for _ in range(10))
    return "zzq" + tail


def scope_key(sites):
    if not sites:
        return "all"
    return "sites-" + "-".join(sorted(s.lower() for s in sites))[:80]


def control_path(engine, scope):
    return state_dir("control", "%s.%s.json" % (engine, scope))


def load_control(engine, sites, refresh=False):
    """Return {noisy: {site: status}, ts, control, cached, sites}."""
    scope = scope_key(sites)
    path = control_path(engine, scope)
    if not refresh and os.path.exists(path):
        try:
            with open(path) as fh:
                data = json.load(fh)
            age_h = (time.time() - data.get("ts", 0)) / 3600.0
            if age_h <= TTL_HOURS:
                data["cached"] = True
                data["age_hours"] = round(age_h, 2)
                return data
        except Exception:  # noqa: BLE001
            pass
    eng = ENGINES.get(engine)
    if not eng or not eng.available:
        return None
    ctrl = control_username()
    try:
        res = eng.run(ctrl, sites=sites, timeout=30)
    except Exception as exc:  # noqa: BLE001
        log("control run failed for %s: %s" % (engine, exc))
        return None
    noisy = {s: v.get("state") for s, v in (res.get("results") or {}).items()
             if v.get("state") == "claimed"}
    data = {
        "engine": engine,
        "scope": scope,
        "sites": sites,
        "control": ctrl,
        "ts": time.time(),
        "probed": res.get("probed"),
        "reported": res.get("reported"),
        "noisy": noisy,
        "cached": False,
        "age_hours": 0.0,
    }
    ensure_dir(state_dir("control"))
    with open(path, "w") as fh:
        json.dump(data, fh)
    return data


def norm(name):
    return re.sub(r"[^a-z0-9]", "", str(name).lower())


# --------------------------------------------------------------------------
# tools
# --------------------------------------------------------------------------


def tool_status(args):
    engines = {}
    for name, eng in ENGINES.items():
        engines[name] = {
            "available": eng.available,
            "binary": eng.bin,
            "version": eng.version() if eng.available else None,
            "data_file": eng.data_file,
            "sites": len(eng.site_entries()) or None,
            "caps": eng.caps,
        }
    ctrl_dir = state_dir("control")
    cache = []
    if os.path.isdir(ctrl_dir):
        for f in sorted(os.listdir(ctrl_dir)):
            try:
                with open(os.path.join(ctrl_dir, f)) as fh:
                    d = json.load(fh)
                cache.append({
                    "file": f,
                    "control": d.get("control"),
                    "noisy_sites": len(d.get("noisy") or {}),
                    "age_hours": round((time.time() - d.get("ts", 0)) / 3600.0, 2),
                })
            except Exception:  # noqa: BLE001
                pass
    writable = True
    try:
        ensure_dir(STATE)
        probe = os.path.join(STATE, ".probe")
        with open(probe, "w") as fh:
            fh.write("ok")
        os.unlink(probe)
    except Exception:  # noqa: BLE001
        writable = False
    return {
        "state_dir": STATE,
        "state_writable": writable,
        "control_ttl_hours": TTL_HOURS,
        "control_cache": cache,
        "engines": engines,
        "proxy_env": {k: v for k, v in os.environ.items()
                      if "proxy" in k.lower()},
    }


def tool_engines(args=None):
    rows = []
    for name, eng in ENGINES.items():
        row = dict(eng.caps)
        row.update({
            "engine": name,
            "available": eng.available,
            "binary": eng.bin,
            "version": eng.version() if eng.available else None,
            "data_sites": len(eng.site_entries()) or None,
            "kind": eng.kind,
            "own_negative_control": name == "maigret",
        })
        rows.append(row)
    return {"engines": rows, "note": (
        "maigret ships a known-claimed and known-unclaimed username per site "
        "in its own DB; sherlock and socialscan do not, which is why the "
        "server runs an explicit control sweep for them.")}


def parse_sites(sites):
    if not sites:
        return None
    if isinstance(sites, str):
        sites = [s.strip() for s in sites.split(",")]
    return [s for s in sites if s] or None


def resolve_engines(spec, kind="sites"):
    avail = available_engines(kind)
    if spec in (None, "", "auto", "all"):
        if spec == "all":
            return avail
        return avail[:1]
    if isinstance(spec, str):
        spec = [s.strip() for s in spec.split(",")]
    wanted = [s for s in spec if s in ENGINES]
    missing = [s for s in spec if s not in ENGINES]
    if missing:
        raise ValueError("unknown engine(s): %s" % ",".join(missing))
    off = [s for s in wanted if s not in avail]
    if off:
        raise ValueError("engine(s) not installed: %s" % ",".join(off))
    return wanted


def run_engines(names, query, sites, timeout, proxy, nsfw, recursion):
    out = {}
    with ThreadPoolExecutor(max_workers=len(names)) as pool:
        futs = {
            pool.submit(ENGINES[n].run, query, sites, timeout, proxy, nsfw,
                        recursion): n
            for n in names
        }
        for fut, name in futs.items():
            try:
                out[name] = fut.result()
            except Exception as exc:  # noqa: BLE001
                out[name] = {"engine": name, "checked": 0, "results": {},
                             "error": "%s: %s" % (type(exc).__name__, exc)}
    return out


def merge_hits(runs, noisy_by_engine, username=""):
    merged = {}
    for engine, run in runs.items():
        noisy = noisy_by_engine.get(engine) or {}
        noisy_by_key = {norm(n): n for n in noisy}
        for name, hit in (run.get("results") or {}).items():
            if hit.get("state") != "claimed":
                continue
            key = norm(name)
            entry = merged.setdefault(key, {
                "site": name,
                "engines": {},
                "confirmed_by": 0,
                "unreliable": False,
            })
            entry["engines"][engine] = {
                "url": hit.get("url"),
                "http_status": hit.get("http_status"),
                "profile": hit.get("profile") or None,
            }
            entry["confirmed_by"] += 1
            if key in noisy_by_key:
                entry["unreliable"] = True
                entry["control_note"] = (
                    "site also reports the control username %s as claimed"
                    % noisy_by_key[key])
    for entry in merged.values():
        urls = [v.get("url") or "" for v in entry["engines"].values()]
        entry["url_contains_username"] = any(
            username.lower() in u.lower() for u in urls if u)
        if not entry["url_contains_username"]:
            entry["warning"] = (
                "no engine returned a URL containing the username: the site "
                "probably answers on a generic page, verify by hand")
        if entry["unreliable"]:
            entry["confidence"] = "unreliable"
        elif entry["confirmed_by"] > 1:
            entry["confidence"] = "confirmed"
        else:
            entry["confidence"] = "single-engine"
    order = {"confirmed": 0, "single-engine": 1, "unreliable": 2}
    return sorted(merged.values(),
                  key=lambda e: (order[e["confidence"]], e["site"].lower()))


def collect_inconclusive(runs):
    out = []
    for engine, run in runs.items():
        for name, hit in (run.get("results") or {}).items():
            if hit.get("state") == "unknown":
                out.append({"site": name, "engine": engine,
                            "note": hit.get("note") or "unknown status"})
    return out


def tool_search_username(args):
    username = (args.get("username") or "").strip()
    if not USERNAME_RE.match(username):
        raise ValueError(
            "username must be 2-64 chars of [A-Za-z0-9._-], got %r" % username)
    sites = parse_sites(args.get("sites"))
    timeout = int(args.get("timeout") or 45)
    proxy = args.get("proxy") or None
    nsfw = bool(args.get("nsfw"))
    recursion = bool(args.get("recursion"))
    control = args.get("control", True) is not False
    engines = resolve_engines(args.get("engines") or "auto")
    started = time.time()

    runs = run_engines(engines, username, sites, timeout, proxy, nsfw, recursion)
    used = list(runs)
    hits_total = sum(sum(1 for h in (r.get("results") or {}).values()
                         if h.get("state") == "claimed")
                     for r in runs.values())
    if (args.get("engines") in (None, "", "auto")) and hits_total == 0:
        extra = [e for e in available_engines() if e not in runs]
        if extra:
            runs.update(run_engines(extra[:1], username, sites, timeout, proxy,
                                    nsfw, recursion))
            used = list(runs)

    noisy_by_engine = {}
    control_info = {"applied": control, "per_engine": {}}
    if control:
        keys = list(used)
        with ThreadPoolExecutor(max_workers=len(keys) or 1) as pool:
            futs = {pool.submit(load_control, eng, sites,
                                bool(args.get("refresh_control"))): eng
                    for eng in keys}
            for fut, eng in futs.items():
                data = fut.result()
                if not data:
                    control_info["per_engine"][eng] = {"available": False}
                    continue
                noisy_by_engine[eng] = data.get("noisy") or {}
                control_info["per_engine"][eng] = {
                    "available": True,
                    "cached": data.get("cached"),
                    "age_hours": data.get("age_hours"),
                    "control_username": data.get("control"),
                    "noisy_count": len(data.get("noisy") or {}),
                    "noisy_sites": sorted(data.get("noisy") or {}),
                    "sites_probed": data.get("probed"),
                }

    found = merge_hits(runs, noisy_by_engine, username)
    unreliable = [e for e in found if e["confidence"] == "unreliable"]
    kept = [e for e in found if e["confidence"] != "unreliable"]
    result = {
        "username": username,
        "engines_run": used,
        "scope": sites or "engine default site list",
        "control": control_info,
        "counts": {
            "confirmed": sum(1 for e in kept if e["confidence"] == "confirmed"),
            "single_engine": sum(1 for e in kept
                                 if e["confidence"] == "single-engine"),
            "dropped_unreliable": len(unreliable),
            "inconclusive": len(collect_inconclusive(runs)),
        },
        "per_engine": {
            e: {"probed": r.get("probed"), "hits": r.get("hits"),
                "reported": r.get("reported"), "error": r.get("error")}
            for e, r in runs.items()
        },
        "engine_errors": {e: r.get("error") for e, r in runs.items()
                          if r.get("error")},
        "found": kept,
        "dropped": unreliable,
        "inconclusive": collect_inconclusive(runs)[:40],
        "elapsed_s": round(time.time() - started, 1),
    }
    return result, runs, control_info, kept, unreliable


def summarize_username(result):
    c = result["counts"]
    lines = ["%s: %d confirmed, %d single-engine, %d dropped as unreliable "
             "(%ss)"
             % (result["username"], c["confirmed"], c["single_engine"],
                c["dropped_unreliable"], result["elapsed_s"])]
    for eng, info in result.get("per_engine", {}).items():
        lines.append("  %s: %s hits, %s probed%s"
                     % (eng, info.get("hits"), info.get("probed"),
                        "" if not info.get("error") else ", error"))
    for e in result["found"][:25]:
        urls = [v.get("url") for v in e["engines"].values() if v.get("url")]
        tags = ",".join(e["engines"])
        lines.append("  [%s] %s (%s) %s"
                     % (e["confidence"], e["site"], tags,
                        urls[0] if urls else ""))
    if len(result["found"]) > 25:
        lines.append("  ... %d more" % (len(result["found"]) - 25))
    if result["dropped"]:
        lines.append("  dropped (control matched): %s"
                     % ", ".join(e["site"] for e in result["dropped"][:15]))
    if result["engine_errors"]:
        lines.append("  engine errors: %s" % json.dumps(result["engine_errors"]))
    return "\n".join(lines)


def tool_verify_username(args):
    username = (args.get("username") or "").strip()
    if not USERNAME_RE.match(username):
        raise ValueError("invalid username %r" % username)
    sites = parse_sites(args.get("sites"))
    if not sites:
        raise ValueError("verify_username needs an explicit 'sites' list; "
                         "use find_sites to build one")
    sub = dict(args)
    sub["sites"] = sites
    sub["engines"] = args.get("engines") or "auto"
    sub["control"] = args.get("control", False)
    return tool_search_username(sub)


def tool_check_email(args):
    email = (args.get("email") or "").strip()
    if not EMAIL_RE.match(email):
        raise ValueError("invalid email %r" % email)
    if not ENGINES["socialscan"].available:
        raise ValueError("socialscan is not installed")
    platforms = parse_sites(args.get("platforms"))
    run = ENGINES["socialscan"].run(email, sites=platforms,
                                    timeout=int(args.get("timeout") or 30))
    taken = {k: v for k, v in run["results"].items()
             if v.get("state") == "claimed"}
    unknown = {k: v for k, v in run["results"].items()
               if v.get("state") == "unknown"}
    return {
        "email": email,
        "registered": sorted(taken),
        "available": sorted(k for k, v in run["results"].items()
                            if v.get("state") == "available"),
        "unknown": {k: v.get("note") for k, v in unknown.items()},
        "note": ("socialscan probes signup endpoints, so a hit means the "
                 "account exists, not that the profile is public"),
        "error": run.get("error"),
    }


def tool_find_sites(args):
    query = (args.get("query") or "").strip().lower()
    engine = args.get("engine") or "sherlock"
    limit = int(args.get("limit") or 40)
    if engine not in ENGINES:
        raise ValueError("unknown engine %r" % engine)
    entries = ENGINES[engine].site_entries()
    if not entries:
        raise ValueError("no site DB found for %s" % engine)
    rows = []
    for name, meta in entries.items():
        tags = meta.get("tags") or []
        if isinstance(tags, str):
            tags = [tags]
        hay = " ".join([name.lower()] + [str(t).lower() for t in tags])
        if query and query not in hay:
            continue
        rows.append({
            "site": name,
            "url_main": meta.get("urlMain"),
            "tags": tags,
            "nsfw": bool(meta.get("isNSFW")),
            "disabled": bool(meta.get("disabled")),
        })
        if len(rows) >= limit:
            break
    return {"engine": engine, "total_in_db": len(entries), "query": query,
            "matched": len(rows), "sites": rows}


def tool_control_report(args):
    engine = args.get("engine")
    names = [engine] if engine else available_engines()
    out = {}
    for name in names:
        if name not in ENGINES:
            continue
        data = load_control(name, None, refresh=bool(args.get("refresh")))
        out[name] = data or {"available": False}
    return {"controls": out}


# --------------------------------------------------------------------------
# MCP plumbing
# --------------------------------------------------------------------------

TOOLS = [
    {
        "name": "status",
        "description": (
            "Health check: which engines are installed, their versions and "
            "site-DB paths, state dir writability, and the age of the cached "
            "negative-control sweeps. Run this before promising a scan."),
        "inputSchema": {"type": "object", "properties": {}},
        "fn": tool_status,
    },
    {
        "name": "engines",
        "description": (
            "Capability matrix for the enumeration engines (sherlock, maigret, "
            "socialscan): site counts, profile parsing, email support, proxy "
            "support, and whether the engine ships its own false-positive "
            "control. Use it to pick the right engine before a scan."),
        "inputSchema": {"type": "object", "properties": {}},
        "fn": tool_engines,
    },
    {
        "name": "search_username",
        "description": (
            "Enumerate public accounts for a username. Runs one or more "
            "engines (sherlock 400+ sites, maigret 3000+ sites with profile "
            "parsing, socialscan signup-API probes) and applies a negative "
            "control sweep: each engine is also run against a username that "
            "cannot exist, and any site that 'finds' it is reported as "
            "unreliable instead of being presented as a hit. Long tool: a full "
            "sherlock sweep takes 1-3 min, a full maigret sweep 5-20 min."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "username": {"type": "string",
                             "description": "username to enumerate (2-64 chars "
                                            "of [A-Za-z0-9._-])"},
                "engines": {
                    "type": "string",
                    "description": "auto (default: sherlock, plus maigret as "
                                   "fallback when sherlock finds nothing), "
                                   "all (every installed engine, union of "
                                   "results), or a comma list of "
                                   "sherlock,maigret,socialscan"},
                "sites": {"type": "string",
                          "description": "optional comma list of site names to "
                                         "restrict the scan (sherlock/maigret "
                                         "site names; use find_sites)"},
                "timeout": {"type": "integer",
                            "description": "per-request timeout in seconds "
                                           "(default 45)"},
                "nsfw": {"type": "boolean",
                         "description": "sherlock only: include NSFW sites"},
                "recursion": {"type": "boolean",
                              "description": "maigret only: follow usernames "
                                             "found on profile pages "
                                             "(default false)"},
                "proxy": {"type": "string",
                          "description": "proxy URL for sherlock/maigret, e.g. "
                                         "socks5://127.0.0.1:1080"},
                "control": {"type": "boolean",
                            "description": "run/reuse the negative-control "
                                           "sweep (default true; disable only "
                                           "when speed matters more than "
                                           "false positives)"},
                "refresh_control": {"type": "boolean",
                                    "description": "force a fresh control "
                                                   "sweep instead of the cache"},
            },
            "required": ["username"],
        },
        "fn": tool_search_username,
        "summary": summarize_username,
    },
    {
        "name": "verify_username",
        "description": (
            "Re-check a username on an explicit list of sites only (fast, "
            "useful to confirm a hit or to test specific platforms). Same "
            "output shape as search_username, control off by default."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "username": {"type": "string"},
                "sites": {"type": "string",
                          "description": "comma list of site names, required"},
                "engines": {"type": "string",
                            "description": "default auto"},
                "timeout": {"type": "integer"},
                "control": {"type": "boolean", "description": "default false"},
            },
            "required": ["username", "sites"],
        },
        "fn": tool_verify_username,
        "summary": summarize_username,
    },
    {
        "name": "check_email",
        "description": (
            "Check where an email address is registered, by probing signup "
            "endpoints (socialscan: GitHub, GitLab, Instagram, Pinterest, "
            "Reddit, Twitter, Tumblr, Firefox). Exact by design, but limited "
            "to those platforms."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "email": {"type": "string"},
                "platforms": {"type": "string",
                              "description": "optional comma list to restrict"},
                "timeout": {"type": "integer"},
            },
            "required": ["email"],
        },
        "fn": tool_check_email,
    },
    {
        "name": "find_sites",
        "description": (
            "Search an engine's site database by name or tag (e.g. 'music', "
            "'forum', 'github') and return site names plus their main URLs. "
            "Use it to build the 'sites' list for verify_username, or to check "
            "whether a platform is covered at all."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string",
                          "description": "substring to match against site name "
                                         "and tags (empty = first N sites)"},
                "engine": {"type": "string",
                           "description": "default sherlock"},
                "limit": {"type": "integer", "description": "default 40"},
            },
        },
        "fn": tool_find_sites,
    },
    {
        "name": "control_report",
        "description": (
            "Show the cached negative-control sweeps: per engine, the control "
            "username used and the sites that claimed it exists (the known "
            "false-positive sites). refresh=true re-runs the sweep."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "engine": {"type": "string",
                           "description": "optional, default all engines"},
                "refresh": {"type": "boolean"},
            },
        },
        "fn": tool_control_report,
    },
]

TOOL_MAP = {t["name"]: t for t in TOOLS}


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def reply(msg_id, result):
    send({"jsonrpc": "2.0", "id": msg_id, "result": result})


def error(msg_id, code, message):
    send({"jsonrpc": "2.0", "id": msg_id,
          "error": {"code": code, "message": message}})


def handle_initialize(params, msg_id):
    reply(msg_id, {
        "protocolVersion": params.get("protocolVersion") or PROTOCOL_VERSION,
        "capabilities": {"tools": {"listChanged": False}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
    })


def call_tool(name, args):
    tool = TOOL_MAP.get(name)
    if not tool:
        return {"content": [{"type": "text", "text": "unknown tool %r" % name}],
                "isError": True}
    try:
        out = tool["fn"](args or {})
    except ValueError as exc:
        return {"content": [{"type": "text", "text": "input error: %s" % exc}],
                "isError": True}
    except Exception as exc:  # noqa: BLE001
        log("tool %s crashed: %s" % (name, exc))
        return {"content": [{"type": "text",
                             "text": "%s failed: %s: %s"
                                     % (name, type(exc).__name__, exc)}],
                "isError": True}
    content = []
    if isinstance(out, tuple):
        payload = out[0]
        if tool.get("summary"):
            content.append({"type": "text", "text": tool["summary"](payload)})
        out = payload
    content.append({"type": "text", "text": json.dumps(out, indent=1,
                                                       ensure_ascii=False)})
    return {"content": content, "isError": False}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}
        if method == "initialize":
            handle_initialize(params, msg_id)
        elif method in ("notifications/initialized", "initialized"):
            continue
        elif method == "tools/list":
            reply(msg_id, {"tools": [
                {"name": t["name"], "description": t["description"],
                 "inputSchema": t["inputSchema"]} for t in TOOLS]})
        elif method == "tools/call":
            reply(msg_id, call_tool(params.get("name"), params.get("arguments")))
        elif method == "ping":
            reply(msg_id, {})
        elif msg_id is not None:
            error(msg_id, -32601, "method not found: %s" % method)


if __name__ == "__main__":
    main()
