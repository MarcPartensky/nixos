"""Read-only IBKR MCP, backed by Interactive Brokers' Flex Web Service.

No account identifier is needed: the Flex token is independent
of the IBKR password, revocable from Client Portal, and the service answers over
HTTPS with no session or 2FA. Cost: reports are generated on demand
(a few seconds), no real-time quotes.

The token and the query identifiers live in a dotenv re-read on EVERY
call (IBKR_FLEX_ENV_FILE): a rotation does not require a restart.
"""

import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

try:
    from mcp.server import MCPServer  # mcp >= 2
except ImportError:
    from mcp.server.fastmcp import FastMCP as MCPServer  # mcp 1.x

BASE = (
    "https://ndcdyn.interactivebrokers.com"
    "/AccountManagement/FlexWebService"
)
UA = "hermes-ibkr-mcp/1.0"
PLACEHOLDER = re.compile(
    r"placeholder|remplacer|set_me|changeme|todo|xxx", re.I
)
# Flex codes that mean "report not ready yet, come back later".
RETRYABLE = {"1001", "1003", "1004", "1005", "1006", "1007", "1008",
             "1019"}

mcp = MCPServer("ibkr-flex")


def _env():
    """Read the dotenv on each call (rotation without restart)."""
    path = os.environ.get("IBKR_FLEX_ENV_FILE", "/run/secrets/ibkr-flex.env")
    values = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                values[key.strip()] = val.strip().strip('"').strip("'")
    return values


def _cred(name):
    value = _env().get(name, "")
    if not value:
        raise RuntimeError(
            f"{name} missing from {os.environ.get('IBKR_FLEX_ENV_FILE')}: "
            "create the Flex token (Client Portal > Performance & Reports > "
            "Flex Queries > Flex Web Service Configuration), put it in "
            "secrets/ibkr.yml then reactivate the system."
        )
    if PLACEHOLDER.search(value):
        raise RuntimeError(
            f"{name} is still a placeholder ({value[:24]}...): the "
            "server is deployed but INERT. Replace the value in "
            "secrets/ibkr.yml and reactivate."
        )
    return value


def _get(url, params, what):
    req = urllib.request.Request(
        f"{url}?{urllib.parse.urlencode(params)}",
        headers={"User-Agent": UA},
    )
    try:
        with urllib.request.urlopen(req, timeout=45) as resp:
            return resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "replace")
        raise RuntimeError(
            f"HTTP {err.code} on {what}: {body[:300]}"
        ) from err
    except urllib.error.URLError as err:
        raise RuntimeError(f"network unreachable on {what}: {err.reason}")


def _fields(xml_text):
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as err:
        raise RuntimeError(
            f"unreadable Flex response ({err}): {xml_text[:300]}"
        ) from err
    return root, {child.tag: (child.text or "").strip() for child in root}


def _send_request(token, query_id, from_date="", to_date="", period=""):
    params = {"t": token, "q": query_id, "v": "3"}
    if from_date and to_date:
        params["fd"] = from_date
        params["td"] = to_date
    elif period:
        params["p"] = period
    text = _get(f"{BASE}/SendRequest", params, "SendRequest")
    _, fields = _fields(text)
    if fields.get("Status") != "Success":
        code = fields.get("ErrorCode", "?")
        msg = fields.get("ErrorMessage", text[:300])
        raise RuntimeError(f"Flex refused the request ({code}): {msg}")
    return fields.get("ReferenceCode", "")


def _fetch(token, query_id, reference, timeout=75):
    deadline = time.time() + timeout
    delay = 2
    while True:
        params = {"t": token, "q": query_id, "v": "3"}
        text = _get(f"{BASE}/GetStatement", params, "GetStatement")
        _, fields = _fields(text)
        if fields.get("Status") == "Success":
            return text
        code = fields.get("ErrorCode", "?")
        msg = fields.get("ErrorMessage", "")
        if code not in RETRYABLE or time.time() >= deadline:
            raise RuntimeError(
                f"Flex report unavailable (reference {reference}, code "
                f"{code}): {msg}"
            )
        time.sleep(delay)
        delay = min(delay * 2, 10)


def _rows(root, section, limit):
    rows = [dict(el.attrib) for el in root.iter(section)]
    if limit and limit > 0:
        rows = rows[:limit]
    return rows


def _sections(root):
    index = {}
    for child in root:
        index[child.tag] = len(list(child))
    return index


def _query_id(arg):
    if arg:
        return arg, arg
    value = _env().get("IBKR_FLEX_QUERY_ID", "")
    if not value or PLACEHOLDER.search(value):
        raise RuntimeError(
            "no Flex query identifier (query_id parameter or key "
            "IBKR_FLEX_QUERY_ID in secrets/ibkr.yml). Create an Activity "
            "Flex Query in Client Portal and set its identifier."
        )
    return value, "IBKR_FLEX_QUERY_ID"


@mcp.tool()
def status() -> dict:
    """Server status: credentials file, token, and real Flex test.

    Call it first: it is the permanent smoke test of the server. A
    "ok" status with an IBKR error code is proof that the whole chain
    works (no account data comes out of it).
    """
    path = os.environ.get("IBKR_FLEX_ENV_FILE", "/run/secrets/ibkr-flex.env")
    env = _env()
    token = env.get("IBKR_FLEX_TOKEN", "")
    query = env.get("IBKR_FLEX_QUERY_ID", "")
    out = {
        "env_file": path,
        "env_file_present": os.path.exists(path),
        "token_present": bool(token),
        "token_placeholder": bool(token) and bool(
            PLACEHOLDER.search(token)
        ),
        "query_id": query or None,
        "trades_query_id": env.get("IBKR_FLEX_TRADES_QUERY_ID") or None,
        "endpoint": f"{BASE}/SendRequest",
    }
    if not token or not query:
        out["flex"] = "not tested: token or query identifier missing"
        return out
    try:
        ref = _send_request(token, query)
        out["flex"] = "ok"
        out["reference_code_received"] = bool(ref)
    except RuntimeError as err:
        out["flex"] = str(err)
    return out


@mcp.tool()
def report(
    query_id: str = "",
    section: str = "",
    from_date: str = "",
    to_date: str = "",
    period: str = "",
    limit: int = 50,
) -> dict:
    """Generate a Flex query and return the report, in clear text and structured.

    query_id: identifier of the Flex query (default: IBKR_FLEX_QUERY_ID).
    section: name of the XML tag to extract (e.g. OpenPosition, Trade,
    CashReportCurrency, EquitySummaryByReportDateInBase). Empty = index of the
    report sections with the row count of each, which is used to
    know what the query contains.
    from_date/to_date: period override in YYYYMMDD format (365 d max).
    period: override as a number of days (e.g. "5").
    limit: max number of rows returned (0 = no limit).
    """
    token = _cred("IBKR_FLEX_TOKEN")
    qid, source = _query_id(query_id)
    ref = _send_request(token, qid, from_date, to_date, period)
    root, _ = _fields(_fetch(token, qid, ref))
    out = {"query_id": qid, "query_id_source": source,
           "reference_code": ref, "generated_at": _now()}
    if section:
        rows = _rows(root, section, limit)
        out["section"] = section
        out["count"] = len(rows)
        out["rows"] = rows
        if not rows:
            out["hint"] = (
                "empty section: either no data for the period, or the "
                "tag is not enabled in the Flex query (add the "
                "section in Client Portal, then re-run)."
            )
    else:
        out["sections"] = _sections(root)
    return out


@mcp.tool()
def positions(query_id: str = "", limit: int = 0) -> dict:
    """Open positions (OpenPosition section): quantity, cost, P&L.

    Reads the activity Flex query. Returns the raw rows as IBKR
    exposes them (each attribute = a report column).
    """
    return report(
        query_id=query_id, section="OpenPosition", limit=limit
    )


@mcp.tool()
def cash(query_id: str = "", limit: int = 0) -> dict:
    """Balances by currency (CashReportCurrency section) and expense account."""
    return report(query_id=query_id, section="CashReportCurrency",
                  limit=limit)


@mcp.tool()
def nav(query_id: str = "", limit: int = 30) -> dict:
    """Net account value over time (NAV in Base)."""
    return report(
        query_id=query_id,
        section="EquitySummaryByReportDateInBase",
        limit=limit,
    )


@mcp.tool()
def trades(days: int = 30, query_id: str = "", limit: int = 50) -> dict:
    """Trades over the last N days.

    Uses IBKR_FLEX_TRADES_QUERY_ID if set (Trade Confirmation Flex
    Query, more reliable for history), otherwise the activity query.
    """
    env = _env()
    qid = query_id or env.get("IBKR_FLEX_TRADES_QUERY_ID", "")
    out = report(query_id=qid, section="Trade", period=str(days),
                 limit=0)
    rows = out.get("rows", [])
    keys = ("tradeDate", "reportDate", "dateTime", "date")
    cutoff = time.strftime(
        "%Y%m%d", time.localtime(time.time() - days * 86400)
    )
    kept = []
    for row in rows:
        stamps = [row[k] for k in keys if row.get(k)]
        if not stamps or any(s[:8] >= cutoff for s in stamps):
            kept.append(row)
    out["rows"] = kept[:limit] if limit > 0 else kept
    out["count"] = len(out["rows"])
    out["cutoff"] = cutoff
    return out


@mcp.tool()
def accounts(query_id: str = "") -> dict:
    """Accounts covered by the Flex query (AccountInformation section)."""
    return report(query_id=query_id, section="AccountInformation")


@mcp.tool()
def raw(query_id: str = "", chars: int = 2000) -> str:
    """Raw Flex report (truncated XML): useful for tuning a query."""
    token = _cred("IBKR_FLEX_TOKEN")
    qid, _ = _query_id(query_id)
    ref = _send_request(token, qid)
    text = _fetch(token, qid, ref)
    return text[:chars]


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


if __name__ == "__main__":
    mcp.run()
