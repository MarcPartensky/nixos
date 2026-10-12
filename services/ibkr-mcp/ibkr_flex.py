"""MCP IBKR en lecture seule, adosse au Flex Web Service d'Interactive Brokers.

Aucun identifiant de compte n'est necessaire : le token Flex est independant
du mot de passe IBKR, revocable depuis Client Portal, et le service repond en
HTTPS sans session ni 2FA. Cout : les rapports sont generes a la demande
(quelques secondes), pas de cotation temps reel.

Le token et les identifiants de requetes vivent dans un dotenv relu a CHAQUE
appel (IBKR_FLEX_ENV_FILE) : une rotation n'exige pas de redemarrage.
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
# Codes Flex qui signifient "rapport pas encore pret, repasse plus tard".
RETRYABLE = {"1001", "1003", "1004", "1005", "1006", "1007", "1008",
             "1019"}

mcp = MCPServer("ibkr-flex")


def _env():
    """Lit le dotenv a chaque appel (rotation sans redemarrage)."""
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
            f"{name} absent de {os.environ.get('IBKR_FLEX_ENV_FILE')} : "
            "creer le token Flex (Client Portal > Performance & Reports > "
            "Flex Queries > Flex Web Service Configuration), le poser dans "
            "secrets/ibkr.yml puis reactiver le systeme."
        )
    if PLACEHOLDER.search(value):
        raise RuntimeError(
            f"{name} vaut encore un placeholder ({value[:24]}...) : le "
            "serveur est deploye mais INERTE. Remplacer la valeur dans "
            "secrets/ibkr.yml et reactiver."
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
            f"HTTP {err.code} sur {what} : {body[:300]}"
        ) from err
    except urllib.error.URLError as err:
        raise RuntimeError(f"reseau injoignable sur {what} : {err.reason}")


def _fields(xml_text):
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as err:
        raise RuntimeError(
            f"reponse Flex illisible ({err}) : {xml_text[:300]}"
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
        raise RuntimeError(f"Flex a refuse la requete ({code}) : {msg}")
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
                f"rapport Flex indisponible (reference {reference}, code "
                f"{code}) : {msg}"
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
            "aucun identifiant de requete Flex (parametre query_id ou cle "
            "IBKR_FLEX_QUERY_ID dans secrets/ibkr.yml). Creer une Activity "
            "Flex Query dans Client Portal et poser son identifiant."
        )
    return value, "IBKR_FLEX_QUERY_ID"


@mcp.tool()
def status() -> dict:
    """Etat du serveur : fichier de credentials, token, et test Flex reel.

    A appeler en premier : c'est le smoke test permanent du serveur. Un
    statut "ok" avec un code d'erreur IBKR est une preuve que la chaine
    complete fonctionne (aucune donnee de compte n'en sort).
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
        out["flex"] = "non teste : token ou identifiant de requete manquant"
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
    """Genere une requete Flex et renvoie le rapport, en clair et structure.

    query_id : identifiant de la Flex query (defaut : IBKR_FLEX_QUERY_ID).
    section : nom de la balise XML a extraire (ex. OpenPosition, Trade,
    CashReportCurrency, EquitySummaryByReportDateInBase). Vide = index des
    sections du rapport avec le nombre de lignes de chacune, ce qui sert a
    savoir ce que contient la requete.
    from_date/to_date : override de periode au format AAAAMMJJ (365 j max).
    period : override en nombre de jours (ex. "5").
    limit : nombre max de lignes renvoyees (0 = pas de limite).
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
                "section vide : soit aucune donnee sur la periode, soit la "
                "balise n'est pas activee dans la Flex query (ajouter la "
                "section dans Client Portal, puis relancer)."
            )
    else:
        out["sections"] = _sections(root)
    return out


@mcp.tool()
def positions(query_id: str = "", limit: int = 0) -> dict:
    """Positions ouvertes (section OpenPosition) : quantite, cout, P&L.

    Lit la Flex query d'activite. Renvoie les lignes brutes telles que IBKR
    les expose (chaque attribut = une colonne du rapport).
    """
    return report(
        query_id=query_id, section="OpenPosition", limit=limit
    )


@mcp.tool()
def cash(query_id: str = "", limit: int = 0) -> dict:
    """Soldes par devise (section CashReportCurrency) et compte de depenses."""
    return report(query_id=query_id, section="CashReportCurrency",
                  limit=limit)


@mcp.tool()
def nav(query_id: str = "", limit: int = 30) -> dict:
    """Valeur nette du compte dans le temps (NAV in Base)."""
    return report(
        query_id=query_id,
        section="EquitySummaryByReportDateInBase",
        limit=limit,
    )


@mcp.tool()
def trades(days: int = 30, query_id: str = "", limit: int = 50) -> dict:
    """Transactions, sur les N derniers jours.

    Utilise IBKR_FLEX_TRADES_QUERY_ID si defini (Trade Confirmation Flex
    Query, plus fiable pour l'historique), sinon la query d'activite.
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
    """Comptes couverts par la Flex query (section AccountInformation)."""
    return report(query_id=query_id, section="AccountInformation")


@mcp.tool()
def raw(query_id: str = "", chars: int = 2000) -> str:
    """Rapport Flex brut (XML tronque) : utile pour regler une requete."""
    token = _cred("IBKR_FLEX_TOKEN")
    qid, _ = _query_id(query_id)
    ref = _send_request(token, qid)
    text = _fetch(token, qid, ref)
    return text[:chars]


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


if __name__ == "__main__":
    mcp.run()
