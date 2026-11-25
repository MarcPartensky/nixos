#!/usr/bin/env python3
"""services/finance-dashboard: spending tracking page for marc.

Chain: Pangolin (finance.marcpartensky.com, SSO) -> newt (site tower)
         -> 127.0.0.1:9142 (this service).

The service computes NOTHING: it reads /var/lib/hermes/workspace/finance/dashboard.json,
written every morning by the "Daily finances recap" cron (finance_recap.py, Wise +
Chase via SimpleFIN), and renders it as HTML with server-generated SVGs.
No JS, no CDN, no dependency outside stdlib: the page opens even if the
network is down, and a displayed figure is always the one from the JSON.

Routes:
  GET /          HTML page (auto-refresh 5 min)
  GET /api/data  the raw JSON
  GET /healthz   200 "ok" (Pangolin/newt healthcheck)
"""

import datetime as dt
import html
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA = os.environ.get(
    "FINANCE_DASHBOARD_DATA", "/var/lib/hermes/workspace/finance/dashboard.json"
)
PORT = int(os.environ.get("FINANCE_DASHBOARD_PORT", "9142"))
HOST = os.environ.get("FINANCE_DASHBOARD_HOST", "0.0.0.0")

# Catppuccin Mocha palette, Lavender accent (marc's preference).
CAT_COLORS = [
    "#b4befe",  # lavender
    "#cba6f7",  # mauve
    "#89b4fa",  # blue
    "#74c7ec",  # sapphire
    "#94e2d5",  # teal
    "#a6e3a1",  # green
    "#f9e2af",  # yellow
    "#fab387",  # peach
    "#f38ba8",  # red
    "#eba0ac",  # maroon
]


def fmt(n, dec=0):
    """French-style amount: narrow no-break space as separator."""
    try:
        v = float(n)
    except (TypeError, ValueError):
        return "?"
    s = f"{v:,.{dec}f}"
    return s.replace(",", "\u202f").replace(".", ",")


def pct(a, b):
    try:
        if not b:
            return None
        return 100.0 * (a - b) / b
    except (TypeError, ValueError):
        return None


def nice_max(v):
    """Rounded scale (25, 50, 100...) for readable ticks."""
    v = max(float(v or 0), 1.0)
    for step in (5, 10, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000, 10000):
        if v <= step * 4:
            return float(step * 4 if v > step * 2 else step * 2)
    return float(int(v / 1000 + 1) * 1000)


def frdate(d):
    """2026-11-12 -> 12/11."""
    d = str(d or "")
    return f"{d[8:10]}/{d[5:7]}" if len(d) >= 10 else d


def esc(s):
    return html.escape(str(s if s is not None else ""))


def load():
    try:
        with open(DATA, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (ValueError, OSError):
        return None


# ------------------------------------------------------------------ charts SVG
def bar_chart(daily, days=30):
    """Daily bars, last day in lavender."""
    pts = (daily or [])[-days:]
    if not pts:
        return '<p class="empty">no data yet</p>'
    w, h = 900, 230
    pad_l, pad_b, pad_t, pad_r = 56, 26, 14, 12
    pw, ph = w - pad_l - pad_r, h - pad_t - pad_b
    vmax = nice_max(max([p.get("eur", 0) for p in pts] + [1.0]))
    step = pw / len(pts)
    bw = max(2.0, step * 0.66)
    out = [
        f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="Daily spending">',
        f'<line x1="{pad_l}" y1="{pad_t}" x2="{pad_l}" y2="{pad_t + ph}" stroke="#45475a"/>',
        f'<line x1="{pad_l}" y1="{pad_t + ph}" x2="{pad_l + pw}" y2="{pad_t + ph}" stroke="#45475a"/>',
    ]
    for frac in (0.5, 1.0):
        y = pad_t + ph - ph * frac
        out.append(
            f'<line x1="{pad_l}" y1="{y:.1f}" x2="{pad_l + pw}" y2="{y:.1f}" '
            'stroke="#313244" stroke-dasharray="3 4"/>'
        )
        out.append(
            f'<text x="{pad_l - 8}" y="{y + 4:.1f}" text-anchor="end" '
            f'class="axis">{fmt(vmax * frac)} €</text>'
        )
    out.append(
        f'<text x="{pad_l - 8}" y="{pad_t + ph + 4}" text-anchor="end" class="axis">0</text>'
    )
    for i, p in enumerate(pts):
        v = p.get("eur", 0) or 0
        bh = ph * (v / vmax)
        x = pad_l + i * step + (step - bw) / 2
        y = pad_t + ph - bh
        last = i == len(pts) - 1
        color = "#b4befe" if last else "#585b70"
        d = p.get("date", "")
        label = d[8:10] + "/" + d[5:7]
        out.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{max(bh, 0.6):.1f}" '
            f'rx="2" fill="{color}"><title>{label} : {fmt(v, 2)} EUR</title></rect>'
        )
        if i % max(1, len(pts) // 6) == 0 or last:
            out.append(
                f'<text x="{x + bw / 2:.1f}" y="{pad_t + ph + 18}" text-anchor="middle" '
                f'class="axis">{label}</text>'
            )
    out.append("</svg>")
    return "".join(out)


def cat_chart(cats30, cats90=None):
    """Horizontal bars by category (30 days)."""
    cats90 = cats90 or {}
    rows = sorted(((k, v) for k, v in (cats30 or {}).items()), key=lambda x: -x[1])
    if not rows:
        return '<p class="empty">no data yet</p>'
    total = sum(v for _, v in rows) or 1.0
    vmax = max(v for _, v in rows)
    out = []
    for i, (name, v) in enumerate(rows):
        color = CAT_COLORS[i % len(CAT_COLORS)]
        width = 100.0 * v / vmax
        share = 100.0 * v / total
        avg90 = cats90.get(name)
        per_month = f" · avg. {fmt(avg90 / 3)} €/month" if avg90 else ""
        out.append(
            f'<div class="cat"><div class="cat-label">{esc(name)}</div>'
            f'<div class="cat-track"><div class="cat-bar" style="width:{max(width, 1):.1f}%;'
            f'background:{color}"></div></div>'
            f'<div class="cat-val"><b>{fmt(v)} €</b>'
            f'<span class="muted">{share:.0f} %{per_month}</span></div></div>'
        )
    return "".join(out)


def cum_chart(curve):
    """Month cumulative, current month vs previous month."""
    cur = (curve or {}).get("current") or []
    prev = (curve or {}).get("previous") or []
    if not cur:
        return '<p class="empty">no data yet</p>'
    w, h = 900, 250
    pad_l, pad_b, pad_t, pad_r = 64, 26, 16, 14
    pw, ph = w - pad_l - pad_r, h - pad_t - pad_b
    vmax = nice_max(max([p.get("cum", 0) for p in cur + prev] + [1.0]))
    nmax = max([len(cur), len(prev), 2])
    px = lambda i: pad_l + pw * (i / max(nmax - 1, 1))  # noqa: E731
    py = lambda v: pad_t + ph - ph * (v / vmax)  # noqa: E731

    def poly(series, color, dash=""):
        if not series:
            return ""
        pts = " ".join(f"{px(i):.1f},{py(p.get('cum', 0)):.1f}" for i, p in enumerate(series))
        d = f' stroke-dasharray="{dash}"' if dash else ""
        return (
            f'<polyline points="{pts}" fill="none" stroke="{color}" '
            f'stroke-width="2.5" stroke-linejoin="round"{d}/>'
        )

    out = [
        f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="Month cumulative">',
        f'<line x1="{pad_l}" y1="{pad_t}" x2="{pad_l}" y2="{pad_t + ph}" stroke="#45475a"/>',
        f'<line x1="{pad_l}" y1="{pad_t + ph}" x2="{pad_l + pw}" y2="{pad_t + ph}" stroke="#45475a"/>',
    ]
    for frac in (0.25, 0.5, 0.75, 1.0):
        y = pad_t + ph - ph * frac
        out.append(
            f'<line x1="{pad_l}" y1="{y:.1f}" x2="{pad_l + pw}" y2="{y:.1f}" '
            'stroke="#313244" stroke-dasharray="3 4"/>'
        )
        out.append(
            f'<text x="{pad_l - 8}" y="{y + 4:.1f}" text-anchor="end" class="axis">'
            f"{fmt(vmax * frac)} €</text>"
        )
    out.append(
        f'<text x="{pad_l - 8}" y="{pad_t + ph + 4}" text-anchor="end" class="axis">0</text>'
    )
    # "today" marker: without it, the current curve looks truncated.
    today_x = px(len(cur) - 1)
    out.append(
        f'<line x1="{today_x:.1f}" y1="{pad_t}" x2="{today_x:.1f}" y2="{pad_t + ph}" '
        'stroke="#b4befe" stroke-opacity="0.35" stroke-dasharray="2 4"/>'
    )
    out.append(
        f'<text x="{today_x - 4:.1f}" y="{pad_t + 10}" text-anchor="end" class="axis">'
        "today</text>"
    )
    out.append(poly(prev, "#7f849c", "6 5"))
    out.append(poly(cur, "#b4befe"))
    for i, p in enumerate(cur):
        out.append(
            f'<circle cx="{px(i):.1f}" cy="{py(p.get("cum", 0)):.1f}" r="2.6" fill="#b4befe">'
            f'<title>on {esc(p.get("date", "")[-2:])} : {fmt(p.get("cum", 0) , 2)} EUR</title></circle>'
        )
    for day in (1, 10, 20, 30):
        if day <= nmax:
            out.append(
                f'<text x="{px(day - 1):.1f}" y="{pad_t + ph + 18}" text-anchor="middle" '
                f'class="axis">{day}</text>'
            )
    out.append("</svg>")
    return "".join(out)


# ------------------------------------------------------------------ page
def kpi(label, value, sub="", accent=False):
    cls = "kpi accent" if accent else "kpi"
    return (
        f'<div class="{cls}"><div class="kpi-label">{esc(label)}</div>'
        f'<div class="kpi-value">{value}</div>'
        f'<div class="kpi-sub">{sub}</div></div>'
    )


def render(p):
    if not p:
        return f"""<!doctype html><meta charset="utf-8">
<title>Finances</title><style>{CSS}</style>
<body><main><h1>Finances</h1>
<p class="empty">No data: <code>{esc(DATA)}</code> is missing.
The "Daily finances recap" cron writes it every morning at 8 AM.</p></main></body>"""

    t = p.get("totals") or {}
    wise = [b for b in (p.get("balances") or {}).get("wise", [])]
    eur = next((b for b in wise if b.get("currency") == "EUR"), {})
    avail = eur.get("amount")
    reserved = eur.get("reserved") or 0
    chase = p.get("chase") or {}
    chase_acc = chase.get("accounts") or []
    checking = next(
        (a for a in chase_acc if "CHECK" in str(a.get("name", "")).upper()),
        chase_acc[0] if chase_acc else None,
    )

    d7, prev7 = t.get("d7") or 0, t.get("prev7") or 0
    delta = pct(d7, prev7)
    if delta is None:
        trend = ""
    else:
        arrow = "▲" if delta > 0 else "▼"
        color = "#f38ba8" if delta > 0 else "#a6e3a1"
        trend = (
            f'<span style="color:{color}">{arrow} {abs(delta):.0f} %</span> '
            f"vs previous 7 days ({fmt(prev7)} €)"
        )

    gen = str(p.get("generated_at", ""))
    gen = f"{frdate(gen)} at {gen[11:16]}" if len(gen) >= 16 else gen[:16]
    day = dt.date.today()
    days_in_month = (
        (day.replace(day=28) + dt.timedelta(days=4)).replace(day=1) - dt.timedelta(days=1)
    ).day

    chase_html = ""
    if checking:
        usd = checking.get("balance")
        chase_html = kpi(
            "Chase checking",
            f"{fmt(usd, 2)} <span class='unit'>USD</span>",
            f"debits 30 d: {fmt(chase.get('debits_30d_usd'))} USD "
            f"({fmt(chase.get('debits_30d_eur'))} €)",
        )
    elif chase.get("errors"):
        chase_html = kpi("Chase", "<span class='bad'>unavailable</span>",
                         esc(chase["errors"][0])[:90])

    tops = "".join(
        f'<li><span>{esc(m.get("name"))}</span><b>{fmt(m.get("eur"))} €</b>'
        f'<span class="muted">{m.get("n", 0)}×</span></li>'
        for m in (p.get("top_merchants_30d") or [])[:8]
    )
    bigs = "".join(
        f'<li><span class="muted">{esc(frdate(x.get("date")))}</span>'
        f'<span>{esc(x.get("name"))}</span><b>{fmt(x.get("eur"))} €</b></li>'
        for x in (p.get("big_tickets_30d") or [])[:6]
    )
    recs = "".join(
        f'<li><span>{esc(r.get("name"))}</span>'
        f'<span class="muted">{r.get("months")} months</span></li>'
        for r in (p.get("recurring") or [])[:8]
    )

    mtd = t.get("mtd") or 0
    proj = mtd / max(day.day, 1) * days_in_month

    return f"""<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="300">
<title>Finances · marc</title><style>{CSS}</style></head>
<body><main>
<header>
  <div>
    <h1>Finances</h1>
    <p class="sub">Wise + Chase · window {esc(p.get("window_days", 90))} d ·
    data from {esc(gen)}</p>
  </div>
</header>

<section class="kpis">
  {kpi("Wise balance", f"{fmt(avail, 2)} <span class='unit'>EUR</span>",
       f"reserved: {fmt(reserved, 2)} €", accent=True)}
  {kpi("last 7 days", f"{fmt(d7)} €", trend)}
  {kpi("30 days", f"{fmt(t.get('d30'))} €",
       f"{fmt(t.get('count_30d'))} operations · before: {fmt(t.get('prev30'))} €")}
  {kpi("Current month", f"{fmt(mtd)} €",
       f"projection: {fmt(proj)} € · same day last month: {fmt(t.get('prev_mtd'))} €")}
  {chase_html}
</section>

<section class="card">
  <h2>Daily spending · 30 days</h2>
  {bar_chart(p.get("daily"), 30)}
</section>

<section class="card">
  <div class="card-head">
    <h2>Month cumulative</h2>
    <div class="legend">
      <span><i style="background:#b4befe"></i>this month</span>
      <span><i class="dash" style="border-color:#7f849c"></i>previous month</span>
    </div>
  </div>
  {cum_chart(p.get("month_curve"))}
  <p class="note">Rent (Roomrs, paid on Chase) is not in these curves:
  it is isolated so as not to crush the pace of regular spending.</p>
</section>

<section class="card">
  <h2>Breakdown by category · 30 days</h2>
  {cat_chart(p.get("cats_30d"), p.get("cats_90d"))}
  <p class="note">Categories = heuristic on the merchant name, not
  Wise's official categories.</p>
</section>

<section class="cols">
  <div class="card"><h2>Top merchants · 30 d</h2><ul class="list">{tops}</ul></div>
  <div class="card"><h2>Biggest tickets · 30 d</h2><ul class="list">{bigs}</ul></div>
  <div class="card"><h2>Recurring subscriptions</h2>
    <ul class="list">{recs or '<li class="muted">none seen over 2 different months</li>'}</ul>
  </div>
</section>

<footer>
  <p>Source: {esc(p.get("source"))} · file <code>{esc(DATA)}</code> ·
  page regenerated on each reload, data refreshed by the 8 AM cron.</p>
</footer>
</main></body></html>"""


CSS = """
:root{
  --base:#1e1e2e; --mantle:#181825; --crust:#11111b; --surface0:#313244;
  --surface1:#45475a; --overlay:#6c7086; --subtext:#a6adc8; --text:#cdd6f4;
  --lavender:#b4befe; --mauve:#cba6f7; --red:#f38ba8; --green:#a6e3a1;
}
*{box-sizing:border-box}
body{margin:0;background:var(--base);color:var(--text);
  font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:1080px;margin:0 auto;padding:28px 20px 60px}
header{display:flex;justify-content:space-between;align-items:flex-end;
  gap:16px;flex-wrap:wrap;margin-bottom:22px}
h1{margin:0;font-size:28px;letter-spacing:-.4px;color:var(--lavender)}
h2{margin:0 0 14px;font-size:15px;font-weight:600;color:var(--subtext);
  text-transform:uppercase;letter-spacing:.08em}
.sub{margin:4px 0 0;color:#9399b2;font-size:13px}
.legend{display:flex;gap:18px;font-size:12.5px;color:#a6adc8}
.legend i{display:inline-block;width:12px;height:10px;border-radius:2px;
  margin-right:6px;vertical-align:middle}
.legend i.dash{background:none!important;border-top:2px dashed #7f849c;
  border-radius:0;height:0;vertical-align:3px}
.card-head{display:flex;justify-content:space-between;align-items:baseline;gap:12px}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));
  gap:12px;margin-bottom:18px}
.kpi{background:var(--mantle);border:1px solid var(--surface0);border-radius:12px;
  padding:14px 16px}
.kpi.accent{border-color:#45475a;background:linear-gradient(180deg,#232334,#181825)}
.kpi-label{font-size:12px;color:#9399b2;text-transform:uppercase;
  letter-spacing:.06em}
.kpi-value{font-size:24px;font-weight:650;margin-top:6px;color:var(--text);
  font-variant-numeric:tabular-nums}
.kpi.accent .kpi-value{color:var(--lavender)}
.kpi-sub{font-size:12.5px;color:#a6adc8;margin-top:6px}
.unit{font-size:13px;color:#9399b2;font-weight:500}
.card{background:var(--mantle);border:1px solid var(--surface0);border-radius:12px;
  padding:18px 18px 12px;margin-bottom:16px}
.cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));
  gap:16px;align-items:start}
svg{width:100%;height:auto;display:block}
.axis{fill:#a6adc8;font-size:12px;font-variant-numeric:tabular-nums}
.cat{display:grid;grid-template-columns:150px 1fr 215px;align-items:center;
  gap:12px;padding:6px 0}
.cat-label{font-size:13.5px;color:var(--subtext)}
.cat-track{background:var(--surface0);border-radius:6px;height:14px;overflow:hidden}
.cat-bar{height:100%;border-radius:6px}
.cat-val{display:flex;gap:10px;justify-content:flex-end;align-items:baseline;
  font-variant-numeric:tabular-nums;font-size:13.5px;white-space:nowrap}
.list{list-style:none;margin:0;padding:0}
.list li{display:flex;gap:8px;justify-content:space-between;align-items:baseline;
  padding:7px 0;border-bottom:1px solid #24243a;font-size:13px}
.list li:last-child{border-bottom:0}
.list b{font-variant-numeric:tabular-nums;color:var(--lavender);font-weight:600}
.muted{color:#9399b2;font-size:12.5px}
.note{margin:8px 0 6px;color:#9399b2;font-size:12.5px}
.empty{color:var(--overlay);padding:24px 0}
.bad{color:var(--red);font-size:18px}
footer{margin-top:26px;color:var(--overlay);font-size:12px}
code{background:var(--crust);padding:1px 5px;border-radius:4px;font-size:11px}
@media(max-width:640px){
  .cat{grid-template-columns:96px 1fr;}
  .cat-val{grid-column:1/-1;justify-content:flex-start}
  .kpi-value{font-size:20px}
}
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "finance-dashboard/1.0"

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        raw = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):  # noqa: N802 - API BaseHTTPRequestHandler
        path = self.path.split("?")[0]
        if path == "/healthz":
            return self._send(200, "ok", "text/plain; charset=utf-8")
        payload = load()
        if path == "/api/data":
            return self._send(
                200,
                json.dumps(payload or {}, ensure_ascii=False, indent=1),
                "application/json; charset=utf-8",
            )
        if path == "/":
            try:
                return self._send(200, render(payload))
            except Exception as e:  # noqa: BLE001 - the page must never 500
                sys.stderr.write(f"render error: {e!r}\n")
                return self._send(500, f"<pre>render error: {esc(e)}</pre>")
        return self._send(404, "not found", "text/plain; charset=utf-8")

    def log_message(self, format, *args):  # noqa: A002, N802 - silence access logs
        return


if __name__ == "__main__":
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    sys.stderr.write(f"finance-dashboard on http://{HOST}:{PORT} data={DATA}\n")
    srv.serve_forever()
