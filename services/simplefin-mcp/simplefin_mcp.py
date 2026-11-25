"""Serveur MCP SimpleFIN (lecture seule) pour hermes.

Expose les comptes et transactions Chase (via le SimpleFIN Bridge) en tools
stdio. L'access URL du Bridge, identifiants Basic compris, est lue dans
SIMPLEFIN_ACCESS_URL (valeur, pratique pour tester) puis
SIMPLEFIN_ACCESS_URL_FILE (chemin, posé par le module depuis /run/secrets).

Limites du Bridge : 24 requêtes par jour, fenêtre de 90 jours maximum, et
l'abonnement doit être réglé (sinon /accounts répond 402 « Payment
required »). Le protocole est en lecture seule :
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

# Le Cloudflare du Bridge renvoie 403 au User-Agent par défaut d'urllib.
UA = {"User-Agent": "hermes-simplefin-mcp/1.0"}
MAX_WINDOW_DAYS = 90
DEFAULT_DAYS = 30
MAX_TX = 1000


def _access_url():
    """Access URL du Bridge : env SIMPLEFIN_ACCESS_URL puis fichier secret."""
    url = os.environ.get("SIMPLEFIN_ACCESS_URL", "").strip()
    if not url:
        path = os.environ.get("SIMPLEFIN_ACCESS_URL_FILE", "")
        if path and os.path.exists(path):
            with open(path) as fh:
                url = fh.read().strip()
    if not url or "@" not in url:
        raise RuntimeError(
            "access URL SimpleFIN absente : SIMPLEFIN_ACCESS_URL (valeur) "
            "ou SIMPLEFIN_ACCESS_URL_FILE (chemin) non configurés."
        )
    return url


def _fetch(start=None, end=None, pending=False, balances_only=False):
    """GET /accounts sur le Bridge ; RuntimeError lisible en cas d'échec."""
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
                "Bridge SimpleFIN : abonnement non réglé (402 Payment "
                f"required) : {body}"
            ) from None
        raise RuntimeError(f"HTTP {err.code} du Bridge SimpleFIN : {body}") from None
    except urllib.error.URLError as err:
        raise RuntimeError(f"Bridge SimpleFIN injoignable ({err.reason})") from None


def _epoch(date_str, end=False):
    """'AAAA-MM-JJ' (UTC) -> epoch ; end=True inclut la journée entière.

    Le paramètre end-date du protocole est EXCLUSIF : on décale d'un jour
    pour que la date demandée soit dans les résultats.
    """
    try:
        day = dt.datetime.strptime(date_str, "%Y-%m-%d").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError:
        raise RuntimeError(
            f"Date « {date_str} » invalide (format attendu : AAAA-MM-JJ)."
        ) from None
    if end:
        day += dt.timedelta(days=1)
    return int(day.timestamp())


def _window(start_date="", days=DEFAULT_DAYS, end_date=""):
    """Bornes epoch (UTC) d'une fenêtre, refusée au-delà de 90 jours."""
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
        raise RuntimeError("Fenêtre vide : start_date est après end_date.")
    if span_days > MAX_WINDOW_DAYS:
        raise RuntimeError(
            f"Fenêtre de {span_days:.0f} jours : le Bridge limite à "
            f"{MAX_WINDOW_DAYS} jours. Réduire start_date ou days."
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
    """Filtre account : id exact ou fragment de nom (insensible à la casse)."""
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
    """État du Bridge SimpleFIN : joignable, abonnement réglé, comptes vus.

    Test de vie (1 requête, soldes seulement). C'est aussi ici que
    remontent les erreurs du Bridge : abonnement non payé (402), connexion
    Chase à réautoriser (con.auth), transaction incomplete (act.failed).
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
    """Comptes liés au Bridge (Chase) : nom, solde, devise, dispo, date.

    Soldes uniquement (1 requête, pas de transactions) : la lecture la moins
    chère pour « combien j'ai sur Chase ». Totaux par devise en bonus.
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
    """Transactions sur une fenêtre bornée (90 jours max), tous comptes.

    start_date/end_date : « AAAA-MM-JJ » UTC ; défaut : les `days` derniers
    jours (30). end_date inclus (le protocole est exclusif, décalé d'un
    jour ici). Les transactions en attente (pending) ne sortent que si
    pending=True. account : id exact ou fragment de nom pour filtrer.
    limit : borne haute du nombre renvoyé (max 1000), tri antéchronologique.
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
    """Cherche un texte dans les descriptions de transactions.

    Filtre côté MCP (insensible à la casse) sur la fenêtre `days` (90 jours
    max, 1 requête) : utile pour retrouver un paiement (« amazon »,
    « airbnb », « loyer »). account filtre par id ou nom.
    """
    start, end = _window("", days, "")
    data = _fetch(start=start, end=end)
    needle = query.strip().lower()
    if not needle:
        raise RuntimeError("query vide : donner un texte à chercher.")
    rows = [r for r in _rows(data, account) if needle in (r["description"] or "").lower()]
    total = len(rows)
    return {
        "transactions": rows[:MAX_TX],
        "nombre_total": total,
        "erreurs": _errs(data),
    }


@mcp.tool()
def spending_summary(days: int = DEFAULT_DAYS, account: str = "") -> dict:
    """Résumé des flux sur la fenêtre : débits, crédits, net, top marchands.

    Par compte et par devise : total des débits (montants négatifs), des
    crédits, net et nombre de transactions. Top 5 marchands par total
    débité (description brute du Bridge, aucune catégorisation). account
    filtre par id ou nom.
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
