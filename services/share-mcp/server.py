"""`share` MCP server: publishes a file and builds the whole chain of links.

One single intent, three legs, in this order:

  1. object    : the file is dropped into the PUBLIC Garage bucket, therefore
                readable anonymously via the website endpoint;
  2. managed short link: Shlink creates a link on s.marcpartensky.com pointing
                to the object (stats, tags, expiry on the Shlink side);
  3. public facade (optional): a 4-character link at x.gd that
                points to the Shlink link, so one more hop to follow but
                a brandable, short URL to share.

Where the files live: the Garage `public` bucket is the ONLY one marked
website, any object entering it is readable by anyone who knows the URL. That is
the price of short links that do not die (a presigned URL would expire before
the link). Do not publish anything here that must stay private.

Key naming: no token, no identifier, no person's name in
the S3 key. With front=True, the x.gd link publicly shows the
destination URL (x.gd exposes a public click counter at `<link>+`), so the
object key ends up published by a third party. The 4-character x.gd facade
is always random: x.gd accepts no custom slug without an account, the chosen
slug therefore only applies to the Shlink link.

Tools:
  - share_publish: drops the file then chains the links (write, requires confirm);
  - share_inventory: what is public right now (objects + Shlink links);
  - share_unpublish: removes the object and deletes the managed link.

Credentials: the application S3 key is read by the module wrapper from
/var/lib/garage/s3-key.env (never in the store), and the Shlink API key
from the sops file. The `aws` binary comes from the PATH set by the wrapper.
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
        raise RuntimeError("Shlink API key missing (SHLINK_API_KEY_FILE)")
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
        return {"status": 0, "error": "unreachable: %s" % e.reason}


def _aws(args, stdin=None):
    cmd = ["aws", "--endpoint-url", S3_ENDPOINT] + args
    try:
        p = subprocess.run(cmd, input=stdin, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except FileNotFoundError:
        return 127, "", "aws binary missing from PATH (module wrapper)"
    except subprocess.TimeoutExpired:
        return 124, "", "timeout (%ss)" % TIMEOUT
    return p.returncode, p.stdout, p.stderr


def _object_key(key):
    key = (key or "").strip().lstrip("/")
    if not key:
        raise ValueError("empty object key")
    if ".." in key.split("/"):
        raise ValueError("key refused (relative path)")
    return key


def _xgd_shorten(url):
    """x.gd facade: POST JSON, returns the slug or raises a readable error."""
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
            return None, "unexpected x.gd response: %s" % json.dumps(d)[:200]
        return "https://x.gd/%s" % code, None
    except Exception as e:  # network, 4xx, JSON: we do not break the chain
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
    """Publishes and chains in one call: S3 -> Shlink link -> x.gd facade.

    path        : local file to drop (absolute path readable by the
                  hermes service: /var/lib/hermes, /tmp, /var/lib/garage).
    object_key  : desired S3 key (default: <prefix>/<file name>). If path
                  is absent, publishes an object ALREADY present in the bucket.
    slug        : slug of the managed short link (default: random Shlink).
    front       : adds a 4-character x.gd link pointing to the managed link.
    valid_until : expiry of the managed link, ISO-8601.

    Real write only if confirm=True (otherwise a preview of what would be
    published). Any object in the public bucket is readable by anyone.
    """
    if path:
        key = _object_key(object_key or "%s/%s" % (PREFIX,
                                                   os.path.basename(path)))
    elif object_key:
        key = _object_key(object_key)
    else:
        return {"error": "give path (local file) or object_key (already in S3)"}

    object_url = "%s/%s" % (PUBLIC_BASE, urllib.parse.quote(key))
    plan = {"object_key": key, "object_url": object_url, "slug": slug,
            "tags": tags or [], "front": front, "valid_until": valid_until}

    if not ALLOW_WRITES:
        return {"dry_run": True, "reason": "SHARE_ALLOW_WRITES=0", **plan}
    if not confirm:
        return {"dry_run": True, "reason": "confirm=True required", **plan}

    out = dict(plan)

    # 1. dropping the object
    if path:
        if not os.path.isfile(path):
            return {"error": "file not found: %s" % path, **out}
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        rc, _, err = _aws(["s3", "cp", path, "s3://%s/%s" % (BUCKET, key),
                           "--content-type", ctype, "--only-show-errors"])
        out["upload"] = {"ok": rc == 0, "content_type": ctype}
        if rc != 0:
            out["error"] = "S3 upload failed: %s" % err.strip()[:400]
            return out
    else:
        rc, _, err = _aws(["s3", "ls", "s3://%s/%s" % (BUCKET, key)])
        if rc != 0 or key.split("/")[-1] not in (_ or ""):
            out["error"] = "object absent from bucket %s: %s" % (BUCKET, key)
            return out
        out["upload"] = {"ok": True, "reused": True}

    # 2. managed short link, with the public link stored in the tags
    link_tags = list(dict.fromkeys(["s3", "public"] + (tags or [])))
    body = {"longUrl": object_url, "tags": link_tags}
    if slug:
        body["customSlug"] = slug
    if valid_until:
        body["validUntil"] = valid_until
    created = _shlink("POST", "/short-urls", body=body)
    out["shlink"] = created
    if created.get("status") not in (200, 201):
        out["error"] = "Shlink link not created: %s" % json.dumps(
            created.get("error"))[:300]
        return out
    short_url = created["body"].get("shortUrl")
    out["short_url"] = short_url

    # 3. optional public facade (the managed link is the target)
    if front:
        front_url, front_err = _xgd_shorten(short_url)
        out["front_url"] = front_url
        if front_err:
            out["front_error"] = front_err
        elif front_url and slug:
            # Trace on the managed link: we re-read the tags and add the facade.
            code = created["body"]["shortCode"]
            cur = _shlink("GET", "/short-urls/" + code)
            cur_tags = (cur.get("body") or {}).get("tags") or []
            _shlink("PATCH", "/short-urls/" + code,
                    body={"tags": list(dict.fromkeys(cur_tags + [front_url]))})
            out["tagged_front"] = True
    return out


@mcp.tool()
def share_inventory(limit: int = 100) -> dict:
    """Everything public: bucket objects + Shlink links tagged `s3`."""
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
    """Removes a public object and, if given, deletes its managed short link."""
    key = _object_key(object_key)
    if not confirm:
        return {"dry_run": True, "reason": "confirm=True required",
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
