"""Serveur MCP shorturl : raccourcisseurs publics ANONYMES a domaine 4 car.

Trois backends seulement, retenus apres sondage des 55 domaines de 4
caracteres des listes korlabs/urlshortener, PeterDaveHello et hagezi : ce sont
les seuls qui cumulent pas de compte, pas de captcha, URL de destination
libre et creation programmatique verifiee.

  1. xgd  (x.gd, 4 car) : API JSON POST /api/v1/shorten, repond 200 avec
     results.id, redirection 302 directe, liens permanents, operateur non
     lucratif. Aucun slug custom sans compte. Backend par defaut.
  2. vgd  (v.gd, 4 car) : API publique GET /create.php?format=json, accepte
     un slug custom (shorturl), liens IMMUABLES (jamais supprimables ni
     modifiables, par design anti-abus), refuse les IP litterales et les
     chaines de raccourcisseurs. Le clic passe par une page d'avertissement.
  3. ttl  (t.tl, 4 car) : POST de formulaire, accepte keyword (slug) et
     expiration. Dernier recours : le domaine est EN VENTE, donc l'operateur
     peut disparaitre du jour au lendemain.

Ecartes volontairement (mesure, pas supposition) : tg.pe et is.gd (5 car),
t.ly / s.ee / s.id / r.im / d.pr (compte ou captcha), 0.gp / 2.gp / 4.gp /
6.gp / 2.ly / 3.ly / 7.ly / 8.ly (Cloudflare Turnstile), t.im / t.mr / l.tl
(reCAPTCHA, refus dur), z.sh (URLs GitHub uniquement, 403 hors de sa page),
d.to (payant), t.co / t.cn / g.co / a.co (plateformes), 4.gg (page de pub).

Aucun secret : ces trois services sont sans compte. Le journal local des
creations (SHORTURL_STATE_DIR, defaut ~/.local/state/shorturl-mcp) sert de
memoire, puisque sans compte il n'existe aucun historique cote service.

PRIORITE DE CONTEXTE : x.gd est le backend par defaut et le seul qui ne
degrade rien de ce que la cible recoit. Mesure du 2026-11-11 : 302 direct,
zero hop, Location identique a la cible, et la cible voit l'IP reelle du
visiteur, son UA reel et le Referer d'origine du shortener. v.gd et t.tl
intercalent une page (un hop de plus, Referer reecrit). Limite commune aux
trois : la query ajoutee au lien court n'est pas forwardee (x.gd et v.gd la
jettent, t.tl l'ajoute a la cible). Pour transmettre des parametres de clic,
c'est shlink avec forward_query=true, pas un backend public.
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

# Matrice de capacites. "kind" decrit la maniere de creer, "caps" ce que le
# backend sait faire sans compte, "risk" le risque de disparition du service.
BACKENDS = {
    "xgd": {
        "domain": "x.gd",
        "domain_len": 4,
        "service": "X.gd",
        "caps": ["shorten", "permanent", "direct_302", "anonymous"],
        "no_caps": ["custom_slug", "expiration", "delete", "edit_afterwards"],
        "risk": "faible (non lucratif, 120M redirections/mois annonces)",
        "notes": "API JSON non documentee mais stable, analytics publiques "
                 "via <lien>+ (compte requis pour les rendre privees)",
    },
    "vgd": {
        "domain": "v.gd",
        "domain_len": 4,
        "service": "v.gd (meme operateur que is.gd)",
        "caps": ["shorten", "custom_slug", "anonymous"],
        "no_caps": ["expiration", "delete", "edit_afterwards"],
        "risk": "faible mais CGU strictes (UK), liens definitifs",
        "notes": "le clic affiche une page d'avertissement avant la cible, "
                 "refuse les IP litterales et les raccourcisseurs en chaine",
    },
    "ttl": {
        "domain": "t.tl",
        "domain_len": 4,
        "service": "T.TL",
        "caps": ["shorten", "custom_slug", "expiration", "anonymous"],
        "no_caps": ["delete"],
        "risk": "ELEVE : le domaine est en vente, service non fiable",
        "notes": "redirection en JS, pas de 302 ; dernier recours seulement",
    },
}

# Ordre de repli par defaut (robustesse -> capacites).
AUTO_ORDER = ["xgd", "vgd", "ttl"]

# Ce que la CIBLE recoit apres un clic, par backend. Mesure, pas supposition :
# seul x.gd laisse la cible devant une requete intacte (302 direct). Les deux
# autres intercalent une page, donc un hop de plus et un Referer reecrit.
CONTEXT = {
    "xgd": {
        "niveau": "riche",
        "hops": 0,
        "referer_vu_par_la_cible": "https://x.gd/ (origine seule)",
        "query_du_clic_forwardee": False,
        "detail": "302 direct, IP et UA reels du visiteur, "
                  "aucun en-tete ajoute",
    },
    "vgd": {
        "niveau": "appauvri",
        "hops": 1,
        "referer_vu_par_la_cible": "https://v.gd/<slug> "
                                   "(page d'avertissement)",
        "query_du_clic_forwardee": False,
        "detail": "page de confirmation cliquable, query du clic jetee",
    },
    "ttl": {
        "niveau": "appauvri",
        "hops": 1,
        "referer_vu_par_la_cible": "origine t.tl (page de saut)",
        "query_du_clic_forwardee": True,
        "detail": "page de saut, mais la query du clic est ajoutee a la cible",
    },
}

# Version lisible du serveur, pour verifier quel binaire repond reellement
# (un gateway non redemarre sert encore l'ancien chemin du store).
REV = "2026-11-11 xgd-first"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Laisse remonter les 3xx au lieu de les suivre."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER_FOLLOW = urllib.request.build_opener()
_OPENER_MANUAL = urllib.request.build_opener(_NoRedirect)


def _request(method, url, body=None, form=None, json_body=None,
             follow=True, timeout=None, allow_3xx=False):
    """Requete HTTP minimale. Rend un dict normalise.

    Ne leve jamais pour un code HTTP : les 3xx/4xx/5xx sont rendus au
    modele avec le corps brut, ce qui rend l'echec diagnosticable.
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
        "%s: %s refuse (HTTP %s) %s corps: %s" % (
            backend, action, res.get("status"), extra,
            (res.get("body") or "")[:400],
        )
    )


def _ok_code(value, limit=MAX_CODE_LEN):
    """Valide un slug : alphanumerique, tiret, underscore, taille bornee."""
    if not value:
        return None
    code = value.strip().strip("/")
    code = unicodedata.normalize("NFKD", code)
    code = "".join(c for c in code if c.isalnum() or c in "-_")
    if not code or len(code) > limit:
        return None
    return code


def _journal(entry):
    """Ajoute une creation au journal local (le seul historique ici)."""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        path = os.path.join(STATE_DIR, "history.jsonl")
        with open(path, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        return path
    except OSError as e:
        return "journal indisponible: %s" % e


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

# Marqueurs des pages de confirmation : v.gd affiche "The full original link
# is shown below", t.tl "Please confirm the URL". Sans un de ces marqueurs on
# ne suit PAS les liens d'une page : sinon n'importe quelle page 200 (GitHub,
# un blog) serait prise pour un saut et la resolution partirait en vrille.
_CONSENT_MARKERS = (
    "destination shown",
    "confirm the url",
    "url jump",
    "you are being redirected",
    "click here to continue",
)


def _page_target(body, host):
    """Rend (genre, cible) si la page se declare redirigeante, sinon (None)."""
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
    """Suit la chaine de redirections, HTTP et pages de confirmation."""
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
        raise _fail("xgd", "reponse non JSON", res)
    code = (payload.get("status") or {}).get("code")
    results = payload.get("results") or {}
    if code != 200 or not results.get("id"):
        raise RuntimeError(
            "xgd: refus (code=%s) %s" % (code, res["body"][:300])
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
        raise _fail("vgd", "reponse non JSON", res)
    if "shorturl" not in payload:
        raise RuntimeError(
            "vgd: refus errorcode=%s %s" % (
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
            "ttl: lien absent de la reponse (HTTP %s) corps: %s"
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
                "warning": "domaine en vente, service non fiable"},
    }


def _create(backend, url, slug=None, expiration=None):
    if backend == "xgd":
        if slug:
            raise RuntimeError(
                "xgd: slug custom impossible sans compte, utiliser vgd ou ttl"
            )
        return _xgd_shorten(url)
    if backend == "vgd":
        if expiration:
            raise RuntimeError(
                "vgd: pas d'expiration, utiliser ttl"
            )
        return _vgd_shorten(url, slug)
    if backend == "ttl":
        return _ttl_shorten(url, slug, expiration)
    raise RuntimeError("backend inconnu: %s" % backend)


def _candidates(backend, slug=None, expiration=None, allow_degrade=False):
    """Backends a essayer, x.gd d'abord.

    Par defaut 'auto' ne propose que x.gd : un repli sur v.gd ou t.tl coute un
    hop intermediaire et un Referer reecrit, donc il faut le demander
    explicitement (allow_degrade=True) au lieu de le subir.
    """
    if backend and backend != "auto":
        name = backend.lower()
        if name not in BACKENDS:
            raise RuntimeError(
                "backend inconnu: %s (disponibles: %s)"
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
                      else "lien cree mais cible non resolue",
        }
    except Exception as e:  # noqa: BLE001 - remonte au modele tel quel
        return {
            "ok": False,
            "latence_ms": int((time.monotonic() - started) * 1000),
            "erreur": str(e)[:400],
        }


@mcp.tool()
def shorturl_backends() -> dict:
    """Matrice des backends : domaine, longueur, capacites, risques.

    A lire avant tout choix de backend. Aucun de ces services ne demande de
    compte ni de captcha, et leurs domaines font 4 caracteres.
    """
    return {
        "backends": BACKENDS,
        "ordre_auto": AUTO_ORDER,
        "defaut": AUTO_ORDER[0],
        "contexte": CONTEXT,
        "rev": REV,
        "rappel": "x.gd par defaut : seul backend sans hop intermediaire ; "
                  "t.tl = domaine en vente",
    }


@mcp.tool()
def shorturl_status(probe: bool = True) -> dict:
    """Etat de chaque backend. probe=True cree un vrai lien jetable et le suit.

    C'est le smoke test du serveur : une creation reelle plus une resolution
    reelle par backend, avec latence et erreur brute si ca casse.
    """
    if not probe:
        return {
            "backends": list(BACKENDS),
            "probe": False,
            "rappel": "probe=True pour tester une creation reelle",
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
    """Cree un lien court anonyme, puis verifie qu'il pointe bien sur url.

    Backend par defaut x.gd, et 'auto' garde x.gd : c'est le seul backend qui
    laisse la cible devant une requete intacte (302 direct, zero hop, IP et UA
    reels du visiteur). allow_degrade=True autorise le repli sur v.gd ou t.tl,
    au prix d'une page intermediaire et d'un Referer reecrit.

    backend: xgd (defaut), vgd (slug custom, lien immuable, page
    d'avertissement), ttl (slug custom + expiration, domaine en vente), ou
    auto. url: destination complete http(s). slug: vgd ou ttl seulement.
    expiration: ttl seulement. verify: suit la redirection une fois le lien
    cree. memo: note libre rangee dans le journal local.
    """
    if not url.lower().startswith(("http://", "https://")):
        raise RuntimeError("url doit commencer par http:// ou https://")
    if slug:
        cleaned = _ok_code(slug)
        if not cleaned:
            raise RuntimeError(
                "slug invalide : alphanumerique, - et _ uniquement, <= %d car"
                % MAX_CODE_LEN
            )
        slug = cleaned
    candidates = _candidates(backend, slug, expiration, allow_degrade)
    errors = []
    for name in candidates:
        try:
            created = _create(name, url, slug, expiration)
        except Exception as e:  # noqa: BLE001 - on tente le suivant
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
                "backend %s : un hop intermediaire s'ajoute et le Referer vu "
                "par la cible devient celui du shortener" % out["backend"]
            )
        ctx["conseil"] = (
            "query du clic transmise a la cible"
            if ctx["query_du_clic_forwardee"] else
            "parametres de clic (?utm, click_id) non transmis : pour les "
            "garder, utiliser shlink avec forward_query=true"
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
        "aucun backend n'a accepte ce lien : %s (allow_degrade=True pour "
        "accepter un hop intermediaire v.gd/t.tl)" % detail
    )


@mcp.tool()
def shorturl_expand(short_url: str, max_hops: int = 10) -> dict:
    """Dedouble un lien court : chaine complete des sauts jusqu'a la cible.

    Gere les redirections HTTP (302) et les redirections ecrites en HTML
    (page d'avertissement v.gd, JS de t.tl), qui sont les deux cas de ces
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
    """Verifie un lien court sans le suivre : code HTTP, Location, type.

    Utile pour savoir si un lien est vivant, s'il redirige en 302 ou par une
    page HTML, et si le service a supprime la cible (404).
    """
    res = _request("GET", short_url, follow=False)
    host = urllib.parse.urlsplit(short_url).netloc
    kind, target = _page_target(res["body"], host)
    if res["status"] == 404:
        state = "mort/retire (404)"
    elif res["location"]:
        state = "redirection HTTP directe"
    elif target:
        state = "page de confirmation (%s) vers %s" % (kind, target)
    else:
        state = "page finale (pas une redirection)"
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
    """Cree plusieurs liens courts d'un coup, en continuant malgre les echecs.

    slug_prefix n'est utilise que si le backend accepte les slugs custom
    (vgd, ttl) : le numero du lien est suffixe. Renvoie aussi le compte
    d'echecs pour ne pas conclure sur un lot partiel.
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
        except Exception as e:  # noqa: BLE001 - on continue le lot
            results.append({"url": url, "erreur": str(e)[:300]})
    return {
        "demandes": len(urls),
        "reussis": ok,
        "echecs": len(urls) - ok,
        "resultats": results,
    }


@mcp.tool()
def shorturl_history(limit: int = 25, search: str | None = None) -> dict:
    """Journal local des liens crees par ce serveur (le seul historique, vu
    qu'aucun de ces services n'en tient sans compte). search filtre sur l'URL
    longue, le lien court ou la note memo."""
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
    """Controle qu'un lien court pointe bien sur l'URL attendue.

    A utiliser apres une creation sur un service dont on ne controle pas la
    destination, ou avant de partager un lien ancien.
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
    """Tente de lire les statistiques publiques d'un lien cree.

    Seul x.gd expose des compteurs lisibles sans compte (page <lien>+), et
    elle est servie par une application JS, donc le resultat peut etre vide :
    renvoyer un compteur absent ne veut pas dire zero clic. v.gd et t.tl
    n'offrent aucune statistique sans compte.
    """
    host = urllib.parse.urlsplit(short_url).netloc
    backend = next(
        (b for b, v in BACKENDS.items() if v["domain"] in host), None
    )
    if backend is None:
        return {"erreur": "lien hors des backends de ce serveur",
                "hote": host}
    if backend != "xgd":
        return {
            "backend": backend,
            "statistiques": None,
            "raison": "aucune statistique publique sans compte sur ce "
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
        "reserve": "page JS : un compteur absent ne signifie pas zero clic",
    }


if __name__ == "__main__":
    mcp.run()
