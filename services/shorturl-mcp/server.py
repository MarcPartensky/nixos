"""shorturl MCP server: public ANONYMOUS shorteners with a 4-char domain.

Only three backends, kept after probing the 55 four-character domains from
the korlabs/urlshortener, PeterDaveHello and hagezi lists: they are the only
ones that combine no account, no captcha, free destination URL and verified
programmatic creation.

  1. xgd  (x.gd, 4 chars): JSON API POST /api/v1/shorten, answers 200 with
     results.id, direct 302 redirect, permanent links, non-profit
     operator. No custom slug without an account. Default backend.
  2. vgd  (v.gd, 4 chars): public API GET /create.php?format=json, accepts
     a custom slug (shorturl), IMMUTABLE links (never deletable nor
     modifiable, by anti-abuse design), refuses literal IPs and
     shortener chains. The click goes through a warning page.
  3. ttl  (t.tl, 4 chars): form POST, accepts keyword (slug) and
     expiration. Last resort: the domain is FOR SALE, so the operator
     can disappear overnight.

Deliberately discarded (measurement, not guess): tg.pe and is.gd (5 chars),
t.ly / s.ee / s.id / r.im / d.pr (account or captcha), 0.gp / 2.gp / 4.gp /
6.gp / 2.ly / 3.ly / 7.ly / 8.ly (Cloudflare Turnstile), t.im / t.mr / l.tl
(reCAPTCHA, hard refusal), z.sh (GitHub URLs only, 403 outside its page),
d.to (paid), t.co / t.cn / g.co / a.co (platforms), 4.gg (ad page).

No secret: these three services are account-less. The local log of the
creations (SHORTURL_STATE_DIR, default ~/.local/state/shorturl-mcp) serves as
memory, since without an account there is no history on the service side.

CONTEXT PRIORITY: x.gd is the default backend and the only one that
degrades nothing of what the target receives. Measurement of 2026-11-11: direct 302,
zero hop, Location identical to the target, and the target sees the real IP of the
visitor, its real UA and the original Referer of the shortener. v.gd and t.tl
insert a page (one more hop, rewritten Referer). Limit common to the
three: the query added to the short link is not forwarded (x.gd and v.gd
throw it away, t.tl adds it to the target). To transmit click parameters,
it is shlink with forward_query=true, not a public backend.
"""

import json
import os
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from html import unescape

from mcp.server.fastmcp import FastMCP

UA = os.environ.get("SHORTURL_UA", "hermes-shorturl-mcp/1.0")
TIMEOUT = float(os.environ.get("SHORTURL_TIMEOUT", "25"))
STATE_DIR = os.environ.get(
    "SHORTURL_STATE_DIR",
    os.path.join(os.path.expanduser("~"), ".local", "state", "shorturl-mcp"),
)
MAX_CODE_LEN = 15

mcp = FastMCP("shorturl")

# Capability matrix. "kind" describes the way to create, "caps" what the
# backend can do without an account, "risk" the risk of the service disappearing.
BACKENDS = {
    "xgd": {
        "domain": "x.gd",
        "domain_len": 4,
        "service": "X.gd",
        "caps": ["shorten", "permanent", "direct_302", "anonymous"],
        "no_caps": ["custom_slug", "expiration", "delete", "edit_afterwards"],
        "risk": "low (non-profit, 120M redirects/month advertised)",
        "notes": "undocumented but stable JSON API, public analytics "
                 "via <link>+ (account required to make them private)",
    },
    "vgd": {
        "domain": "v.gd",
        "domain_len": 4,
        "service": "v.gd (same operator as is.gd)",
        "caps": ["shorten", "custom_slug", "anonymous"],
        "no_caps": ["expiration", "delete", "edit_afterwards"],
        "risk": "low but strict ToS (UK), permanent links",
        "notes": "the click shows a warning page before the target, "
                 "refuses literal IPs and chained shorteners",
    },
    "ttl": {
        "domain": "t.tl",
        "domain_len": 4,
        "service": "T.TL",
        "caps": ["shorten", "custom_slug", "expiration", "anonymous"],
        "no_caps": ["delete"],
        "risk": "HIGH: the domain is for sale, unreliable service",
        "notes": "JS redirect, no 302; last resort only",
    },
}

# Default fallback order (robustness -> capabilities).
AUTO_ORDER = ["xgd", "vgd", "ttl"]

# What the TARGET receives after a click, per backend. Measurement, not guess:
# only x.gd leaves the target in front of an intact request (direct 302). The two
# others insert a page, hence one more hop and a rewritten Referer.
CONTEXT = {
    "xgd": {
        "niveau": "rich",
        "hops": 0,
        "referer_vu_par_la_cible": "https://x.gd/ (origin only)",
        "query_du_clic_forwardee": False,
        "detail": "direct 302, real IP and UA of the visitor, "
                  "no header added",
    },
    "vgd": {
        "niveau": "degraded",
        "hops": 1,
        "referer_vu_par_la_cible": "https://v.gd/<slug> "
                                   "(warning page)",
        "query_du_clic_forwardee": False,
        "detail": "clickable confirmation page, click query discarded",
    },
    "ttl": {
        "niveau": "degraded",
        "hops": 1,
        "referer_vu_par_la_cible": "t.tl origin (jump page)",
        "query_du_clic_forwardee": True,
        "detail": "jump page, but the click query is added to the target",
    },
}

# Human-readable version of the server, to check which binary really answers
# (a gateway not restarted still serves the old store path).
REV = "2026-11-11 xgd-first"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Lets 3xx bubble up instead of following them."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER_FOLLOW = urllib.request.build_opener()
_OPENER_MANUAL = urllib.request.build_opener(_NoRedirect)


def _request(method, url, body=None, form=None, json_body=None,
             follow=True, timeout=None, allow_3xx=False):
    """Minimal HTTP request. Returns a normalized dict.

    Never raises for an HTTP code: 3xx/4xx/5xx are returned to the
    model with the raw body, which makes the failure diagnosable.
    """
    data = None
    headers = {"User-Agent": UA, "Accept": "*/*"}
    if json_body is not None:
        data = json.dumps(json_body).encode()
        headers["Content-Type"] = "application/json"
    elif form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = body
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method=method)
    opener = _OPENER_FOLLOW if follow else _OPENER_MANUAL
    started = time.monotonic()
    try:
        with opener.open(req, timeout=timeout or TIMEOUT) as r:
            raw = r.read().decode("utf-8", "replace")
            return {
                "status": r.status,
                "body": raw,
                "location": r.headers.get("Location"),
                "final_url": r.geturl(),
                "ms": int((time.monotonic() - started) * 1000),
            }
    except urllib.error.HTTPError as e:
        raw = ""
        try:
            raw = e.read().decode("utf-8", "replace")
        except Exception:
            raw = ""
        return {
            "status": e.code,
            "body": raw,
            "location": e.headers.get("Location") if e.headers else None,
            "final_url": url,
            "ms": int((time.monotonic() - started) * 1000),
        }
    except urllib.error.URLError as e:
        raise RuntimeError(
            "injoignable: %s %s (%s)" % (method, url, e.reason)
        )


def _fail(backend, action, res, extra=""):
    return RuntimeError(
        "%s: %s refused (HTTP %s) %s body: %s" % (
            backend, action, res.get("status"), extra,
            (res.get("body") or "")[:400],
        )
    )


def _ok_code(value, limit=MAX_CODE_LEN):
    """Validates a slug: alphanumeric, hyphen, underscore, bounded size."""
    if not value:
        return None
    code = value.strip().strip("/")
    code = unicodedata.normalize("NFKD", code)
    code = "".join(c for c in code if c.isalnum() or c in "-_")
    if not code or len(code) > limit:
        return None
    return code


def _journal(entry):
    """Adds a creation to the local log (the only history here)."""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        path = os.path.join(STATE_DIR, "history.jsonl")
        with open(path, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        return path
    except OSError as e:
        return "journal unavailable: %s" % e


def _read_journal(limit=50):
    path = os.path.join(STATE_DIR, "history.jsonl")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        lines = [ln for ln in f.read().splitlines() if ln.strip()]
    out = []
    for ln in lines[-max(1, int(limit)):]:
        try:
            out.append(json.loads(ln))
        except ValueError:
            continue
    return list(reversed(out))


_ASSET_RE = re.compile(
    r"\.(js|css|png|ico|svg|jpg|jpeg|gif|webp|woff2?|ttf)(\?|$)", re.I
)

# Markers of the confirmation pages: v.gd shows "The full original link
# is shown below", t.tl "Please confirm the URL". Without one of these markers we
# do NOT follow the links of a page: otherwise any 200 page (GitHub,
# a blog) would be taken for a jump and the resolution would go haywire.
_CONSENT_MARKERS = (
    "destination shown",
    "confirm the url",
    "url jump",
    "you are being redirected",
    "click here to continue",
)


def _page_target(body, host):
    """Returns (kind, target) if the page declares itself redirecting, otherwise (None)."""
    if not body:
        return (None, None)
    text = unescape(body)
    patterns = [
        ("meta", r'http-equiv=["\']?refresh["\']?[^>]*content=["\']?'
                 r'[^"\'>]*url=([^"\';>\s]+)'),
        ("js", r'w(?:indow)?\.location(?:\.href|\.replace)?\s*=?\s*\(?\s*'
               r'["\'](https?://[^"\']+)["\']'),
        ("anchor", r'<a[^>]+id=["\']url["\'][^>]+href=["\']'
                   r'(https?://[^"\']+)["\']'),
    ]
    for kind, pat in patterns:
        m = re.search(pat, text, re.I | re.S)
        if m and host not in m.group(1):
            return (kind, m.group(1).strip())
    low = text.lower()
    if not any(marker in low for marker in _CONSENT_MARKERS):
        return (None, None)
    for m in re.finditer(r'href=["\'](https?://[^"\']+)["\']', text, re.I):
        url = m.group(1)
        if host in url or _ASSET_RE.search(url):
            continue
        if re.search(r"/(css|js|img|assets|fonts?)/", url, re.I):
            continue
        return ("consent", url)
    return (None, None)


def _resolve(short_url, max_hops=10):
    """Follows the chain of redirections, HTTP and confirmation pages."""
    hops = []
    current = short_url.strip()
    for _ in range(max(1, int(max_hops))):
        host = urllib.parse.urlsplit(current).netloc
        res = _request("GET", current, follow=False)
        entry = {
            "url": current,
            "status": res["status"],
            "ms": res["ms"],
        }
        if res["location"]:
            entry["via"] = "http"
            entry["to"] = res["location"]
            hops.append(entry)
            current = urllib.parse.urljoin(current, res["location"])
            continue
        kind, target = _page_target(res["body"], host)
        if target:
            entry["via"] = kind
            entry["to"] = target
            hops.append(entry)
            current = urllib.parse.urljoin(current, target)
            continue
        entry["via"] = "final"
        entry["body_excerpt"] = " ".join(
            re.sub(r"<[^>]*>", " ", res["body"]).split()
        )[:200]
        hops.append(entry)
        break
    return hops


def _xgd_shorten(url):
    res = _request("POST", "https://x.gd/api/v1/shorten",
                   json_body={"url": url})
    if res["status"] != 200:
        raise _fail("xgd", "POST /api/v1/shorten", res)
    try:
        payload = json.loads(res["body"])
    except ValueError:
        raise _fail("xgd", "non-JSON response", res)
    code = (payload.get("status") or {}).get("code")
    results = payload.get("results") or {}
    if code != 200 or not results.get("id"):
        raise RuntimeError(
            "xgd: refused (code=%s) %s" % (code, res["body"][:300])
        )
    return {
        "backend": "xgd",
        "short_url": "https://x.gd/%s" % results["id"],
        "slug": results["id"],
        "long_url": results.get("url") or url,
        "expires": None,
        "raw": payload,
    }


def _vgd_shorten(url, slug=None):
    query = {"format": "json", "url": url}
    if slug:
        query["shorturl"] = slug
    res = _request(
        "GET", "https://v.gd/create.php?" + urllib.parse.urlencode(query)
    )
    try:
        payload = json.loads(res["body"])
    except ValueError:
        raise _fail("vgd", "non-JSON response", res)
    if "shorturl" not in payload:
        raise RuntimeError(
            "vgd: refused errorcode=%s %s" % (
                payload.get("errorcode"), payload.get("errormessage"),
            )
        )
    short = payload["shorturl"]
    return {
        "backend": "vgd",
        "short_url": short,
        "slug": short.rstrip("/").split("/")[-1],
        "long_url": url,
        "expires": None,
        "raw": payload,
    }


def _ttl_shorten(url, slug=None, expiration=None):
    form = {"url": url}
    if slug:
        form["keyword"] = slug
    if expiration:
        form["expiration"] = str(expiration)
    res = _request("POST", "https://t.tl/", form=form)
    if res["status"] != 200:
        raise _fail("ttl", "POST /", res)
    m = re.search(
        r'id=["\']shortUrl["\'][^>]*>\s*(https?://[^<\s]+)', res["body"]
    )
    if not m:
        raise RuntimeError(
            "ttl: link missing from the response (HTTP %s) body: %s"
            % (res["status"], res["body"][:300])
        )
    short = m.group(1)
    return {
        "backend": "ttl",
        "short_url": short,
        "slug": short.rstrip("/").split("/")[-1],
        "long_url": url,
        "expires": expiration,
        "raw": {"unstable": True,
                "warning": "domain for sale, unreliable service"},
    }


def _create(backend, url, slug=None, expiration=None):
    if backend == "xgd":
        if slug:
            raise RuntimeError(
                "xgd: custom slug impossible without an account, use vgd or ttl"
            )
        return _xgd_shorten(url)
    if backend == "vgd":
        if expiration:
            raise RuntimeError(
                "vgd: no expiration, use ttl"
            )
        return _vgd_shorten(url, slug)
    if backend == "ttl":
        return _ttl_shorten(url, slug, expiration)
    raise RuntimeError("unknown backend: %s" % backend)


def _candidates(backend, slug=None, expiration=None, allow_degrade=False):
    """Backends to try, x.gd first.

    By default 'auto' proposes only x.gd: a fallback to v.gd or t.tl costs an
    intermediate hop and a rewritten Referer, so it must be requested
    explicitly (allow_degrade=True) instead of suffered.
    """
    if backend and backend != "auto":
        name = backend.lower()
        if name not in BACKENDS:
            raise RuntimeError(
                "unknown backend: %s (available: %s)"
                % (backend, ", ".join(BACKENDS))
            )
        return [name]
    if expiration:
        return ["ttl"]
    if slug:
        return [b for b in AUTO_ORDER if "custom_slug" in BACKENDS[b]["caps"]]
    return list(AUTO_ORDER) if allow_degrade else [AUTO_ORDER[0]]


def _probe_one(backend):
    started = time.monotonic()
    try:
        created = _create(backend, "https://example.com/shorturl-mcp-probe")
        hops = _resolve(created["short_url"], max_hops=3)
        final = hops[-1].get("to") or hops[-1]["url"]
        reachable = "example.com" in final
        return {
            "ok": reachable,
            "latence_ms": int((time.monotonic() - started) * 1000),
            "lien_cree": created["short_url"],
            "destination_finale": final,
            "mode_redirection": hops[0]["via"],
            "detail": "creation + resolution OK" if reachable
                      else "link created but target not resolved",
        }
    except Exception as e:  # noqa: BLE001 - bubbles up to the model as-is
        return {
            "ok": False,
            "latence_ms": int((time.monotonic() - started) * 1000),
            "erreur": str(e)[:400],
        }


@mcp.tool()
def shorturl_backends() -> dict:
    """Matrix of the backends: domain, length, capabilities, risks.

    To be read before any backend choice. None of these services asks for an
    account nor a captcha, and their domains are 4 characters.
    """
    return {
        "backends": BACKENDS,
        "ordre_auto": AUTO_ORDER,
        "defaut": AUTO_ORDER[0],
        "contexte": CONTEXT,
        "rev": REV,
        "rappel": "x.gd by default: only backend without an intermediate hop; "
                  "t.tl = domain for sale",
    }


@mcp.tool()
def shorturl_status(probe: bool = True) -> dict:
    """State of each backend. probe=True creates a real disposable link and follows it.

    This is the smoke test of the server: a real creation plus a real
    resolution per backend, with latency and raw error if it breaks.
    """
    if not probe:
        return {
            "backends": list(BACKENDS),
            "probe": False,
            "rappel": "probe=True to test a real creation",
        }
    return {
        "horodatage": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "resultats": {b: _probe_one(b) for b in BACKENDS},
    }


@mcp.tool()
def shorturl_shorten(url: str, backend: str = "auto", slug: str | None = None,
                     expiration: str | None = None, verify: bool = True,
                     memo: str | None = None,
                     allow_degrade: bool = False) -> dict:
    """Creates an anonymous short link, then verifies it points to url.

    Default backend x.gd, and 'auto' keeps x.gd: it is the only backend that
    leaves the target in front of an intact request (direct 302, zero hop, real IP and UA
    of the visitor). allow_degrade=True allows the fallback to v.gd or t.tl,
    at the cost of an intermediate page and a rewritten Referer.

    backend: xgd (default), vgd (custom slug, immutable link, warning
    page), ttl (custom slug + expiration, domain for sale), or
    auto. url: full http(s) destination. slug: vgd or ttl only.
    expiration: ttl only. verify: follows the redirect once the link is
    created. memo: free note stored in the local log.
    """
    if not url.lower().startswith(("http://", "https://")):
        raise RuntimeError("url must start with http:// or https://")
    if slug:
        cleaned = _ok_code(slug)
        if not cleaned:
            raise RuntimeError(
                "invalid slug: alphanumeric, - and _ only, <= %d chars"
                % MAX_CODE_LEN
            )
        slug = cleaned
    candidates = _candidates(backend, slug, expiration, allow_degrade)
    errors = []
    for name in candidates:
        try:
            created = _create(name, url, slug, expiration)
        except Exception as e:  # noqa: BLE001 - we try the next one
            errors.append({"backend": name, "erreur": str(e)[:300]})
            continue
        out = dict(created)
        out["demande"] = {
            "url": url, "backend": backend, "slug": slug,
            "expiration": expiration,
        }
        out["replis"] = errors
        ctx = dict(CONTEXT[out["backend"]])
        if out["backend"] != "xgd":
            ctx["alerte"] = (
                "backend %s: an intermediate hop is added and the Referer seen "
                "by the target becomes that of the shortener" % out["backend"]
            )
        ctx["conseil"] = (
            "click query forwarded to the target"
            if ctx["query_du_clic_forwardee"] else
            "click parameters (?utm, click_id) not forwarded: to "
            "keep them, use shlink with forward_query=true"
        )
        out["contexte"] = ctx
        if verify:
            hops = _resolve(out["short_url"], max_hops=5)
            final = hops[-1].get("to") or hops[-1]["url"]
            out["verification"] = {
                "sauts": len(hops),
                "destination_finale": final,
                "destination_ok": url.rstrip("/") in final
                or final.rstrip("/") == url.rstrip("/"),
                "mode": hops[0]["via"],
            }
        out["journal"] = _journal({
            "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "backend": out["backend"],
            "short_url": out["short_url"],
            "long_url": url,
            "memo": memo,
        })
        return out
    detail = json.dumps(errors, ensure_ascii=False)
    raise RuntimeError(
        "no backend accepted this link: %s (allow_degrade=True to "
        "accept an intermediate hop v.gd/t.tl)" % detail
    )


@mcp.tool()
def shorturl_expand(short_url: str, max_hops: int = 10) -> dict:
    """Unfolds a short link: full chain of hops up to the target.

    Handles HTTP redirections (302) and redirections written in HTML
    (v.gd warning page, t.tl JS), which are the two cases of these
    backends.
    """
    hops = _resolve(short_url, max_hops)
    return {
        "entree": short_url,
        "sauts": hops,
        "destination_finale": hops[-1].get("to") or hops[-1]["url"],
        "nb_sauts": len(hops),
    }


@mcp.tool()
def shorturl_check(short_url: str) -> dict:
    """Checks a short link without following it: HTTP code, Location, type.

    Useful to know whether a link is alive, whether it redirects in 302 or via an
    HTML page, and whether the service has removed the target (404).
    """
    res = _request("GET", short_url, follow=False)
    host = urllib.parse.urlsplit(short_url).netloc
    kind, target = _page_target(res["body"], host)
    if res["status"] == 404:
        state = "dead/removed (404)"
    elif res["location"]:
        state = "direct HTTP redirect"
    elif target:
        state = "confirmation page (%s) to %s" % (kind, target)
    else:
        state = "final page (not a redirect)"
    return {
        "url": short_url,
        "status": res["status"],
        "location": res["location"],
        "cible_si_page_confirmation": target,
        "type": state,
        "latence_ms": res["ms"],
        "excerpt": " ".join(
            re.sub(r"<[^>]*>", " ", res["body"]).split()
        )[:200],
    }


@mcp.tool()
def shorturl_bulk_shorten(urls: list[str], backend: str = "auto",
                          slug_prefix: str | None = None,
                          allow_degrade: bool = False) -> dict:
    """Creates several short links at once, continuing despite failures.

    slug_prefix is used only if the backend accepts custom slugs
    (vgd, ttl): the link number is suffixed. Also returns the failure
    count so as not to conclude on a partial batch.
    """
    results = []
    ok = 0
    for i, url in enumerate(urls, 1):
        slug = _ok_code("%s%d" % (slug_prefix, i)) if slug_prefix else None
        try:
            out = shorturl_shorten(url=url, backend=backend, slug=slug,
                                   verify=False,
                                   allow_degrade=allow_degrade)
            ok += 1
            results.append({"url": url, "short_url": out["short_url"],
                            "backend": out["backend"],
                            "replis": out.get("replis")})
        except Exception as e:  # noqa: BLE001 - we continue the batch
            results.append({"url": url, "erreur": str(e)[:300]})
    return {
        "demandes": len(urls),
        "reussis": ok,
        "echecs": len(urls) - ok,
        "resultats": results,
    }


@mcp.tool()
def shorturl_history(limit: int = 25, search: str | None = None) -> dict:
    """Local log of the links created by this server (the only history, since
    none of these services keeps one without an account). search filters on the long
    URL, the short link or the memo note."""
    entries = _read_journal(limit=200 if search else limit)
    if search:
        needle = search.lower()
        entries = [
            e for e in entries
            if needle in json.dumps(e, ensure_ascii=False).lower()
        ][:max(1, int(limit))]
    return {"dossier": STATE_DIR, "nb": len(entries), "entrees": entries}


@mcp.tool()
def shorturl_verify(short_url: str, expected_url: str) -> dict:
    """Checks that a short link points to the expected URL.

    To be used after a creation on a service whose destination we do not
    control, or before sharing an old link.
    """
    def _norm(value):
        return value.strip().rstrip("/")

    hops = _resolve(short_url, max_hops=10)
    final = hops[-1].get("to") or hops[-1]["url"]
    same = _norm(final) == _norm(expected_url)
    return {
        "short_url": short_url,
        "attendue": expected_url,
        "destination_finale": final,
        "conforme": same,
        "sauts": hops,
    }


@mcp.tool()
def shorturl_analytics(short_url: str) -> dict:
    """Attempts to read the public statistics of a created link.

    Only x.gd exposes counters readable without an account (<link>+ page), and
    it is served by a JS application, so the result may be empty:
    returning an absent counter does not mean zero clicks. v.gd and t.tl
    offer no statistics without an account.
    """
    host = urllib.parse.urlsplit(short_url).netloc
    backend = next(
        (b for b, v in BACKENDS.items() if v["domain"] in host), None
    )
    if backend is None:
        return {"erreur": "link outside the backends of this server",
                "hote": host}
    if backend != "xgd":
        return {
            "backend": backend,
            "statistiques": None,
            "raison": "no public statistics without an account on this "
                      "backend",
        }
    res = _request("GET", short_url.rstrip("/") + "+", follow=True)
    text = " ".join(re.sub(r"<[^>]*>", " ", res["body"]).split())
    numbers = re.findall(r"\b(\d{1,9})\b", text)[:10]
    links = re.findall(r'"id"\s*:\s*"([A-Za-z0-9_-]{4,15})"', res["body"])
    return {
        "backend": "xgd",
        "status": res["status"],
        "url_finale": res["final_url"],
        "nombres_lus": numbers,
        "liens_vus": links[:5],
        "texte_extrait": text[:400],
        "reserve": "JS page: an absent counter does not mean zero clicks",
    }


if __name__ == "__main__":
    mcp.run()
