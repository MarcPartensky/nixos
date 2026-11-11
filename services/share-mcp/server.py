"""Serveur MCP `share` : publie un fichier et fabrique toute la chaîne de liens.

Une seule intention, trois jambes, dans cet ordre :

  1. objet    : le fichier est déposé dans le bucket PUBLIC de Garage, donc
                lisible en anonyme via l'endpoint website ;
  2. lien court géré : Shlink crée un lien sur s.marcpartensky.com qui pointe
                sur l'objet (stats, tags, expiration côté Shlink) ;
  3. façade publique (optionnelle) : un lien de 4 caractères chez x.gd qui
                pointe sur le lien Shlink, donc un saut de plus à suivre mais
                une URL brandable et courte à partager.

Où vivent les fichiers : le bucket `public` de Garage est le SEUL marqué
website, tout objet qui y entre est lisible par quiconque connaît l'URL. C'est
le prix de liens courts qui ne meurent pas (une URL présignée expirerait avant
le lien). Ne rien publier ici qui doive rester privé.

Nommage des clés : pas de token, ni d'identifiant, ni de nom de personne dans
la clé S3. Avec front=True, le lien x.gd affiche publiquement l'URL de
destination (x.gd expose un compteur de clics public sur `<lien>+`), donc la
clé d'objet se retrouve publiée par un tiers. La façade x.gd de 4 caractères
est toujours aléatoire : x.gd n'accepte aucun slug custom sans compte, le slug
choisi ne s'applique donc qu'au lien Shlink.

Outils :
  - share_publish : dépose puis chaîne les liens (écriture, exige confirm) ;
  - share_inventory : ce qui est public en ce moment (objets + liens Shlink) ;
  - share_unpublish : retire l'objet et supprime le lien géré.

Identifiants : la clé S3 applicative est lue par le wrapper du module depuis
/var/lib/garage/s3-key.env (jamais dans le store), et la clé de l'API Shlink
depuis le fichier sops. Le binaire `aws` vient du PATH posé par le wrapper.
"""

import json
import mimetypes
import os
import shlex
import subprocess
import urllib.error
import urllib.parse
import urllib.request

from mcp.server.fastmcp import FastMCP

BUCKET = os.environ.get("SHARE_BUCKET", "public")
PUBLIC_BASE = os.environ.get(
    "SHARE_PUBLIC_BASE", "https://files.marcpartensky.com/public"
).rstrip("/")
S3_ENDPOINT = os.environ.get("SHARE_S3_ENDPOINT", "http://127.0.0.1:3900")
PREFIX = os.environ.get("SHARE_PREFIX", "share").strip("/")

SHLINK_URL = os.environ.get("SHLINK_URL", "http://127.0.0.1:8097").rstrip("/")
SHLINK_KEY_FILE = os.environ.get("SHLINK_API_KEY_FILE", "")
ALLOW_WRITES = os.environ.get("SHARE_ALLOW_WRITES", "1") == "1"
TIMEOUT = float(os.environ.get("SHARE_TIMEOUT", "600"))

mcp = FastMCP("share")


def _shlink_key():
    key = ""
    if SHLINK_KEY_FILE:
        try:
            with open(SHLINK_KEY_FILE) as f:
                key = f.read().strip()
        except OSError:
            key = ""
    key = key or os.environ.get("SHLINK_API_KEY", "")
    if not key:
        raise RuntimeError("clé d'API Shlink absente (SHLINK_API_KEY_FILE)")
    return key


def _shlink(method, path, query=None, body=None):
    url = SHLINK_URL + "/rest/v3" + path
    clean = {k: v for k, v in (query or {}).items() if v is not None}
    if clean:
        url += "?" + urllib.parse.urlencode(clean, doseq=True)
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Accept": "application/json", "X-Api-Key": _shlink_key()}
    if data:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode("utf-8", "replace")
            return {"status": r.status, "body": json.loads(raw) if raw else {}}
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = raw[:1500]
        return {"status": e.code, "error": payload}
    except urllib.error.URLError as e:
        return {"status": 0, "error": "injoignable: %s" % e.reason}


def _aws(args, stdin=None):
    cmd = ["aws", "--endpoint-url", S3_ENDPOINT] + args
    try:
        p = subprocess.run(cmd, input=stdin, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except FileNotFoundError:
        return 127, "", "binaire aws absent du PATH (wrapper du module)"
    except subprocess.TimeoutExpired:
        return 124, "", "délai dépassé (%ss)" % TIMEOUT
    return p.returncode, p.stdout, p.stderr


def _object_key(key):
    key = (key or "").strip().lstrip("/")
    if not key:
        raise ValueError("clé d'objet vide")
    if ".." in key.split("/"):
        raise ValueError("clé refusée (chemin relatif)")
    return key


def _xgd_shorten(url):
    """Façade x.gd : POST JSON, rend le slug ou lève une erreur lisible."""
    body = json.dumps({"url": url}).encode()
    req = urllib.request.Request(
        "https://x.gd/api/v1/shorten", data=body, method="POST",
        headers={"Content-Type": "application/json",
                 "User-Agent": "hermes-share-mcp/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            d = json.loads(r.read().decode() or "{}")
        code = ((d.get("results") or {}).get("id") or "").strip()
        if not code:
            return None, "réponse x.gd inattendue: %s" % json.dumps(d)[:200]
        return "https://x.gd/%s" % code, None
    except Exception as e:  # réseau, 4xx, JSON: on ne casse pas la chaîne
        return None, "x.gd: %s" % e


@mcp.tool()
def share_publish(
    path: str | None = None,
    object_key: str | None = None,
    slug: str | None = None,
    tags: list[str] | None = None,
    front: bool = False,
    valid_until: str | None = None,
    confirm: bool = False,
) -> dict:
    """Publie et chaîne en un appel : S3 -> lien Shlink -> façade x.gd.

    path        : fichier local à déposer (chemin absolu lisible par le
                  service hermes : /var/lib/hermes, /tmp, /var/lib/garage).
    object_key  : clé S3 voulue (défaut: <prefixe>/<nom du fichier>). Si path
                  est absent, publie un objet DÉJÀ présent dans le bucket.
    slug        : slug du lien court géré (défaut: aléatoire Shlink).
    front       : ajoute un lien x.gd de 4 caractères pointant sur le lien géré.
    valid_until : expiration du lien géré, ISO-8601.

    Écriture réelle seulement si confirm=True (sinon aperçu de ce qui serait
    publié). Tout objet du bucket public est lisible par n'importe qui.
    """
    if path:
        key = _object_key(object_key or "%s/%s" % (PREFIX,
                                                   os.path.basename(path)))
    elif object_key:
        key = _object_key(object_key)
    else:
        return {"error": "donner path (fichier local) ou object_key (déjà en S3)"}

    object_url = "%s/%s" % (PUBLIC_BASE, urllib.parse.quote(key))
    plan = {"object_key": key, "object_url": object_url, "slug": slug,
            "tags": tags or [], "front": front, "valid_until": valid_until}

    if not ALLOW_WRITES:
        return {"dry_run": True, "reason": "SHARE_ALLOW_WRITES=0", **plan}
    if not confirm:
        return {"dry_run": True, "reason": "confirm=True requis", **plan}

    out = dict(plan)

    # 1. dépôt de l'objet
    if path:
        if not os.path.isfile(path):
            return {"error": "fichier introuvable: %s" % path, **out}
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        rc, _, err = _aws(["s3", "cp", path, "s3://%s/%s" % (BUCKET, key),
                           "--content-type", ctype, "--only-show-errors"])
        out["upload"] = {"ok": rc == 0, "content_type": ctype}
        if rc != 0:
            out["error"] = "échec du dépôt S3: %s" % err.strip()[:400]
            return out
    else:
        rc, _, err = _aws(["s3", "ls", "s3://%s/%s" % (BUCKET, key)])
        if rc != 0 or key.split("/")[-1] not in (_ or ""):
            out["error"] = "objet absent du bucket %s: %s" % (BUCKET, key)
            return out
        out["upload"] = {"ok": True, "reused": True}

    # 2. lien court géré, avec le lien public enregistré dans les tags
    link_tags = list(dict.fromkeys(["s3", "public"] + (tags or [])))
    body = {"longUrl": object_url, "tags": link_tags}
    if slug:
        body["customSlug"] = slug
    if valid_until:
        body["validUntil"] = valid_until
    created = _shlink("POST", "/short-urls", body=body)
    out["shlink"] = created
    if created.get("status") not in (200, 201):
        out["error"] = "lien Shlink non créé: %s" % json.dumps(
            created.get("error"))[:300]
        return out
    short_url = created["body"].get("shortUrl")
    out["short_url"] = short_url

    # 3. façade publique optionnelle (le lien géré est la cible)
    if front:
        front_url, front_err = _xgd_shorten(short_url)
        out["front_url"] = front_url
        if front_err:
            out["front_error"] = front_err
        elif front_url and slug:
            # Trace sur le lien géré : on relit les tags et on ajoute la façade.
            code = created["body"]["shortCode"]
            cur = _shlink("GET", "/short-urls/" + code)
            cur_tags = (cur.get("body") or {}).get("tags") or []
            _shlink("PATCH", "/short-urls/" + code,
                    body={"tags": list(dict.fromkeys(cur_tags + [front_url]))})
            out["tagged_front"] = True
    return out


@mcp.tool()
def share_inventory(limit: int = 100) -> dict:
    """Tout ce qui est public : objets du bucket + liens Shlink tagués `s3`."""
    rc, stdout, err = _aws(["s3", "ls", "--recursive", "s3://%s/" % BUCKET])
    objects = []
    if rc == 0:
        for line in stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                objects.append({"size": int(parts[2]),
                                "key": " ".join(parts[3:]),
                                "url": "%s/%s" % (PUBLIC_BASE,
                                                  urllib.parse.quote(
                                                      " ".join(parts[3:])))})
    links = _shlink("GET", "/short-urls",
                    {"tags[]": ["s3"], "itemsPerPage": min(limit, 100)})
    return {
        "bucket": BUCKET,
        "objects": objects[:limit],
        "objects_total": len(objects),
        "s3_error": None if rc == 0 else err.strip()[:300],
        "shlink_links": [
            {"shortUrl": u.get("shortUrl"), "longUrl": u.get("longUrl"),
             "tags": u.get("tags"),
             "visits": (u.get("visitsSummary") or {}).get("total")}
            for u in ((links.get("body") or {}).get("shortUrls", {})
                      .get("data") or [])
        ],
    }


@mcp.tool()
def share_unpublish(
    object_key: str, short_code: str | None = None, confirm: bool = False
) -> dict:
    """Retire un objet public et, si donné, supprime son lien court géré."""
    key = _object_key(object_key)
    if not confirm:
        return {"dry_run": True, "reason": "confirm=True requis",
                "object_key": key, "short_code": short_code}
    rc, _, err = _aws(["s3", "rm", "s3://%s/%s" % (BUCKET, key)])
    out = {"object_key": key, "deleted_object": rc == 0}
    if rc != 0:
        out["error"] = err.strip()[:300]
    if short_code:
        out["shlink"] = _shlink("DELETE", "/short-urls/" + shlex.quote(
            short_code).strip("'"))
    return out


if __name__ == "__main__":
    mcp.run()
