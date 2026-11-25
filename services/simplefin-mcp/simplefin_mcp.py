"""SimpleFIN MCP server (read-only) for hermes.

Exposes Chase accounts and transactions (via the SimpleFIN Bridge) as stdio
tools. The Bridge access URL, Basic credentials included, is read from
SIMPLEFIN_ACCESS_URL (value, handy for testing) then
SIMPLEFIN_ACCESS_URL_FILE (path, set by the module from /run/secrets).

Bridge limits: 24 requests per day, 90-day maximum window, and
the subscription must be paid (otherwise /accounts responds 402 "Payment
required"). The protocol is read-only:
https://www.simplefin.org/protocol.html
"""

import base64
import collections
import datetime as dt
import json
import os
import urllib.error
import urllib.parse
import urllib.request

try:
    from mcp.server import MCPServer  # mcp >= 2
except ImportError:
    from mcp.server.fastmcp import FastMCP as MCPServer  # mcp 1.x

mcp = MCPServer("simplefin")

# The Bridge's Cloudflare returns 403 for urllib's default User-Agent.
UA = {"User-Agent": "hermes-simplefin-mcp/1.0"}
MAX_WINDOW_DAYS = 90
DEFAULT_DAYS = 30
MAX_TX = 1000


def _access_url():
    """Bridge access URL: env SIMPLEFIN_ACCESS_URL then secret file."""
    url = os.environ.get("SIMPLEFIN_ACCESS_URL", "").strip()
    if not url:
        path = os.environ.get("SIMPLEFIN_ACCESS_URL_FILE", "")
        if path and os.path.exists(path):
            with open(path) as fh:
                url = fh.read().strip()
    if not url or "@" not in url:
        raise RuntimeError(
            "SimpleFIN access URL missing: SIMPLEFIN_ACCESS_URL (value) "
            "or SIMPLEFIN_ACCESS_URL_FILE (path) not configured."
        )
    return url


def _fetch(start=None, end=None, pending=False, balances_only=False):
    """GET /accounts on the Bridge; readable RuntimeError on failure."""
    url = _access_url()
    scheme, rest = url.split("//", 1)
    auth, host = rest.rsplit("@", 1)
    basic = base64.b64encode(auth.encode()).decode()
    params = {"version": "2"}
    if start:
        params["start-date"] = str(int(start))
    if end:
        params["end-date"] = str(int(end))
    if pending:
        params["pending"] = "1"
    if balances_only:
        params["balances-only"] = "1"
    req = urllib.request.Request(
        f"{scheme}//{host}/accounts?" + urllib.parse.urlencode(params),
        headers={**UA, "Authorization": "Basic " + basic},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as err:
        body = err.read().decode(errors="replace")[:400]
        if err.code == 402:
            raise RuntimeError(
                "SimpleFIN Bridge: subscription not paid (402 Payment "
                f"required): {body}"
            ) from None
        raise RuntimeError(f"HTTP {err.code} from the SimpleFIN Bridge: {body}") from None
    except urllib.error.URLError as err:
        raise RuntimeError(f"SimpleFIN Bridge unreachable ({err.reason})") from None


def _epoch(date_str, end=False):
    """'YYYY-MM-DD' (UTC) -> epoch; end=True includes the whole day.

    The protocol's end-date parameter is EXCLUSIVE: we shift by one day
    so that the requested date is in the results.
    """
    try:
        day = dt.datetime.strptime(date_str, "%Y-%m-%d").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError:
        raise RuntimeError(
            f"Invalid date '{date_str}' (expected format: YYYY-MM-DD)."
        ) from None
    if end:
        day += dt.timedelta(days=1)
    return int(day.timestamp())


def _window(start_date="", days=DEFAULT_DAYS, end_date=""):
    """Epoch bounds (UTC) of a window, refused beyond 90 days."""
    today = dt.datetime.now(dt.timezone.utc)
    midnight = today.replace(hour=0, minute=0, second=0, microsecond=0)
    days = max(1, min(int(days), MAX_WINDOW_DAYS))
    end = (
        _epoch(end_date, end=True)
        if end_date
        else int((midnight + dt.timedelta(days=1)).timestamp())
    )
    start = (
        _epoch(start_date)
        if start_date
        else int((midnight - dt.timedelta(days=days)).timestamp())
    )
    span_days = (end - start) / 86400
    if span_days <= 0:
        raise RuntimeError("Empty window: start_date is after end_date.")
    if span_days > MAX_WINDOW_DAYS:
        raise RuntimeError(
            f"Window of {span_days:.0f} days: the Bridge limits to "
            f"{MAX_WINDOW_DAYS} days. Reduce start_date or days."
        )
    return start, end


def _conn_names(data):
    return {
        c.get("conn_id"): (c.get("name") or c.get("org_name") or "?")
        for c in data.get("connections") or []
    }


def _errs(data):
    return [
        {"code": e.get("code"), "msg": e.get("msg")}
        for e in data.get("errlist") or []
    ]


def _account(acc, conns):
    return {
        "id": acc.get("id"),
        "nom": acc.get("name"),
        "institution": conns.get(acc.get("conn_id")),
        "devise": acc.get("currency"),
        "solde": acc.get("balance"),
        "solde_dispo": acc.get("available-balance"),
        "solde_maj": acc.get("balance-date"),
    }


def _tx(tx, acc, conns):
    posted = tx.get("posted")
    return {
        "id": tx.get("id"),
        "date": (
            dt.datetime.fromtimestamp(posted, dt.timezone.utc).strftime("%Y-%m-%d")
            if posted
            else None
        ),
        "montant": tx.get("amount"),
        "description": tx.get("description"),
        "compte": acc.get("name"),
        "institution": conns.get(acc.get("conn_id")),
    }


def _keep_account(acc, account):
    """account filter: exact id or name fragment (case-insensitive)."""
    if not account:
        return True
    return account == str(acc.get("id")) or account.lower() in str(
        acc.get("name") or ""
    ).lower()


def _rows(data, acc_filter="", pending_meta=False):
    conns = _conn_names(data)
    rows = []
    for acc in data.get("accounts") or []:
        if not _keep_account(acc, acc_filter):
            continue
        for tx in acc.get("transactions") or []:
            row = _tx(tx, acc, conns)
            if pending_meta and tx.get("pending") is not None:
                row["pending"] = bool(tx.get("pending"))
            rows.append(row)
    rows.sort(key=lambda r: r["date"] or "", reverse=True)
    return rows


def _clamp_limit(limit):
    return max(1, min(int(limit), MAX_TX))


@mcp.tool()
def status() -> dict:
    """SimpleFIN Bridge status: reachable, subscription paid, accounts seen.

    Liveness test (1 request, balances only). This is also where the
    Bridge errors surface: unpaid subscription (402), Chase connection
    to reauthorize (con.auth), incomplete transaction (act.failed).
    """
    data = _fetch(balances_only=True)
    conns = _conn_names(data)
    accounts = data.get("accounts") or []
    return {
        "bridge": "ok",
        "connexions": [
            {"nom": c.get("name"), "org_url": c.get("org_url")}
            for c in data.get("connections") or []
        ],
        "institutions": sorted({v for v in conns.values() if v}),
        "comptes": [
            {
                "nom": a.get("name"),
                "devise": a.get("currency"),
                "solde": a.get("balance"),
            }
            for a in accounts
        ],
        "erreurs": _errs(data),
    }


@mcp.tool()
def list_accounts() -> dict:
    """Accounts linked to the Bridge (Chase): name, balance, currency, available, date.

    Balances only (1 request, no transactions): the cheapest read
    for "how much do I have on Chase". Totals per currency as a bonus.
    """
    data = _fetch(balances_only=True)
    conns = _conn_names(data)
    accounts = [_account(a, conns) for a in data.get("accounts") or []]
    totals = {}
    for a in accounts:
        try:
            totals[a["devise"]] = round(
                totals.get(a["devise"], 0.0) + float(a["solde"] or 0), 2
            )
        except (TypeError, ValueError):
            continue
    return {
        "comptes": accounts,
        "totaux_par_devise": totals,
        "erreurs": _errs(data),
    }


@mcp.tool()
def get_transactions(
    start_date: str = "",
    end_date: str = "",
    days: int = DEFAULT_DAYS,
    pending: bool = False,
    account: str = "",
    limit: int = 200,
) -> dict:
    """Transactions over a bounded window (90 days max), all accounts.

    start_date/end_date: "YYYY-MM-DD" UTC; default: the last `days`
    days (30). end_date included (the protocol is exclusive, shifted by one
    day here). Pending transactions only come out if
    pending=True. account: exact id or name fragment to filter.
    limit: upper bound on the number returned (max 1000), reverse-chronological order.
    """
    start, end = _window(start_date, days, end_date)
    data = _fetch(start=start, end=end, pending=pending)
    rows = _rows(data, account, pending_meta=True)
    total = len(rows)
    return {
        "transactions": rows[: _clamp_limit(limit)],
        "nombre_total": total,
        "erreurs": _errs(data),
    }


@mcp.tool()
def search_transactions(query: str, days: int = MAX_WINDOW_DAYS, account: str = "") -> dict:
    """Searches for text in transaction descriptions.

    Filter on the MCP side (case-insensitive) over the `days` window (90 days
    max, 1 request): useful to find a payment ("amazon",
    "airbnb", "loyer"). account filters by id or name.
    """
    start, end = _window("", days, "")
    data = _fetch(start=start, end=end)
    needle = query.strip().lower()
    if not needle:
        raise RuntimeError("empty query: give some text to search for.")
    rows = [r for r in _rows(data, account) if needle in (r["description"] or "").lower()]
    total = len(rows)
    return {
        "transactions": rows[:MAX_TX],
        "nombre_total": total,
        "erreurs": _errs(data),
    }


@mcp.tool()
def spending_summary(days: int = DEFAULT_DAYS, account: str = "") -> dict:
    """Summary of the flows over the window: debits, credits, net, top merchants.

    Per account and per currency: total debits (negative amounts), credits,
    net and number of transactions. Top 5 merchants by total
    debited (raw Bridge description, no categorization). account
    filters by id or name.
    """
    start, end = _window("", days, "")
    data = _fetch(start=start, end=end)
    per_account = []
    merchants = collections.defaultdict(float)
    for acc in data.get("accounts") or []:
        if not _keep_account(acc, account):
            continue
        debits = credits = 0.0
        count = 0
        for tx in acc.get("transactions") or []:
            try:
                amount = float(tx.get("amount") or 0)
            except (TypeError, ValueError):
                continue
            count += 1
            if amount < 0:
                debits += amount
                merchants[tx.get("description") or "?"] += amount
            else:
                credits += amount
        per_account.append(
            {
                "compte": acc.get("name"),
                "devise": acc.get("currency"),
                "transactions": count,
                "debits": round(debits, 2),
                "credits": round(credits, 2),
                "net": round(debits + credits, 2),
            }
        )
    top = sorted(merchants.items(), key=lambda kv: kv[1])[:5]
    return {
        "fenetre_jours": max(1, min(int(days), MAX_WINDOW_DAYS)),
        "comptes": per_account,
        "top_marchands": [
            {"description": desc, "total": round(total, 2)} for desc, total in top
        ],
        "erreurs": _errs(data),
    }


if __name__ == "__main__":
    mcp.run()
