"""MCP server for Enable Banking (PSD2 AIS, personal use).

Read-only access to real European bank accounts (e.g. Caisse
d'Epargne via BPCE): balances, details, transactions. Auth: a
self-signed RSA JWT per request, from the app JSON at
ENABLE_BANKING_APP_FILE (re-read every call, for sops):
  {"app_id": "uuid", "private_key": "-----BEGIN ... PRIVATE KEY"}
Optional: ENABLE_BANKING_BASE_URI (default
https://api.enablebanking.com).
"""

import base64
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
except ImportError as exc:  # pragma: no cover
    raise SystemExit("cryptography is required: %s" % exc)

try:
    from mcp.server import MCPServer
except ImportError:
    from mcp.server.fastmcp import FastMCP as MCPServer

BASE = os.environ.get(
    "ENABLE_BANKING_BASE_URI", "https://api.enablebanking.com"
).rstrip("/")

mcp = MCPServer("enable-banking")


def _b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _app():
    path = os.environ.get("ENABLE_BANKING_APP_FILE", "")
    if not path:
        raise RuntimeError("ENABLE_BANKING_APP_FILE is not set")
    data = json.loads(Path(path).read_text())
    if "PLACEHOLDER" in json.dumps(data):
        raise RuntimeError(
            "Enable Banking app secret is still the PLACEHOLDER: "
            "marc must register the app in the control panel and "
            "the sops file secrets/enable-banking.yml must be "
            "recreated with the real app_id + private_key."
        )
    return data["app_id"], data["private_key"]


def _jwt():
    app_id, pem = _app()
    key = serialization.load_pem_private_key(
        pem.encode(), password=None
    )
    now = int(time.time())
    header = {"typ": "JWT", "alg": "RS256", "kid": app_id}
    body = {
        "iss": "enablebanking.com",
        "aud": "api.enablebanking.com",
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = (
        _b64url(json.dumps(header).encode())
        + "."
        + _b64url(json.dumps(body).encode())
    )
    sig = key.sign(
        signing_input.encode(), padding.PKCS1v15(), hashes.SHA256()
    )
    return signing_input + "." + _b64url(sig)


def _http(method, path, body=None):
    headers = {
        "Accept": "application/json",
        "Authorization": "Bearer " + _jwt(),
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(
        BASE + path, data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(
            "HTTP %d on %s %s: %s" % (exc.code, method, path, detail)
        ) from None
    except urllib.error.URLError as exc:
        raise RuntimeError(
            "Network error on %s %s: %s" % (method, path, exc.reason)
        ) from None


@mcp.tool()
def status():
    """Smoke test: sign a JWT and fetch the app info.

    No bank calls. Returns name, environment (SANDBOX/PRODUCTION)
    and status (Active/Inactive/Pending). Inactive means no account
    has been linked ("Activate by linking accounts" in the control
    panel).
    """
    return _http("GET", "/application")


@mcp.tool()
def list_institutions(country: str = "FR", contains: str = ""):
    """List supported banks (ASPSPs).

    Pass the returned country+name to connection_create() (Enable
    Banking identifies banks by country+name, not by id). contains:
    case-insensitive substring on the name, e.g. "epargne" (each
    French Caisse d'Epargne region appears separately).
    """
    data = _http(
        "GET", "/aspsps?country=%s&service=accounts" % country.upper()
    )
    out = []
    for bank in data:
        name = bank.get("name", "")
        if contains and contains.lower() not in name.lower():
            continue
        out.append({
            "country": bank.get("country"),
            "name": name,
            "id": bank.get("id"),
        })
    return out


@mcp.tool()
def connection_create(aspsp_name: str,
                      country: str = "FR",
                      redirect_url: str = "https://example.org/",
                      valid_days: int = 180,
                      psu_type: str = "personal"):
    """Start linking a bank: returns the authorization URL for the
    user to open in a browser.

    Read-only consent (balances+transactions) on the bank's own PSD2
    page, for Caisse d'Epargne strong auth goes through the Banxo
    app. redirect_url must be whitelisted on the app registration;
    the page itself does not matter. After the user approves, the
    browser lands on redirect_url?code=...&state=...; pass that
    code to session_create(). valid_days: consent duration (banks
    cap around 90-180 days, then re-link).
    """
    valid_until = time.strftime(
        "%Y-%m-%dT%H:%M:%S.000000+00:00",
        time.gmtime(time.time() + valid_days * 86400),
    )
    state = base64.urlsafe_b64encode(os.urandom(12)).decode()
    return _http("POST", "/auth", {
        "access": {"balances": True, "transactions": True,
                   "valid_until": valid_until},
        "aspsp": {"country": country.upper(), "name": aspsp_name},
        "redirect_url": redirect_url,
        "state": state,
        "psu_type": psu_type,
    })


@mcp.tool()
def session_create(code: str):
    """Exchange the ?code=... from the redirect for a session.

    Returns session_id plus the account uids now readable by the
    app. Save the uids for the account_* tools.
    """
    return _http("POST", "/sessions", {"code": code})


@mcp.tool()
def session_get(session_id: str):
    """Session status: consent validity, psu_id, linked accounts."""
    return _http("GET", "/sessions/%s" % session_id)


@mcp.tool()
def session_delete(session_id: str):
    """Revoke (delete) a session/consent. IRREVERSIBLE: reading the
    bank again requires a new browser authorization."""
    return _http("DELETE", "/sessions/%s" % session_id)


@mcp.tool()
def account_details(account_id: str):
    """Account metadata: holder name, IBAN, BIC, currency, type."""
    return _http("GET", "/accounts/%s/details" % account_id)


@mcp.tool()
def account_balances(account_id: str):
    """Balances of one account (list of amount+currency entries,
    CLBD = booked, etc.)."""
    return _http("GET", "/accounts/%s/balances" % account_id)


@mcp.tool()
def account_transactions(account_id: str, date_from: str = "",
                         date_to: str = "", status_filter: str = "",
                         continuation: str = ""):
    """Transactions for one account.

    date_from/date_to: ISO dates (YYYY-MM-DD), optional.
    status_filter: BOOKed only ("BOOK") or pending ("PNDT"), empty
    = booked. Paged: pass back the continuation_key returned by a
    previous call to fetch the next page.
    """
    bits = []
    if date_from:
        bits.append("date_from=%s" % date_from)
    if date_to:
        bits.append("date_to=%s" % date_to)
    if status_filter:
        bits.append("transaction_status=%s" % status_filter)
    if continuation:
        bits.append("continuation_key=%s" % continuation)
    return _http(
        "GET",
        "/accounts/%s/transactions?%s" % (account_id, "&".join(bits)),
    )


if __name__ == "__main__":
    mcp.run()
