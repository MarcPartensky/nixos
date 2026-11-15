#!/usr/bin/env python3
"""Schemas SVG du README (style des docs droplify).

Principe : un schema = une idee, des objets concrets. Vrais noms de services,
vrais domaines, aucune prose abstraite dans les boites. Regles de geometrie du
skill droplify-publishing (largeur monospace = len * size * 0.6, hauteurs
calculees, 40 px entre deux couches), plus un controle qui fait echouer le build
si un texte sort de sa boite ou du canevas.

    python3 build.py
"""
from html import escape
import os
import re

BASE, SURF = "#1e1e2e", "#313244"
TEXT, MUT, DIM = "#cdd6f4", "#9399b2", "#6c7086"
LAV, BLU, TEAL = "#b4befe", "#89b4fa", "#94e2d5"
GRN, YEL, PEACH = "#a6e3a1", "#f9e2af", "#fab387"
MAU, RED, SKY, PINK = "#cba6f7", "#f38ba8", "#89dceb", "#f5c2e7"

MONO = "ui-monospace, SFMono-Regular, Menlo, monospace"
SANS = "ui-sans-serif, system-ui, -apple-system, sans-serif"
CW = 0.6
WARN = []


def warn(m):
    WARN.append(m)


def w_of(s, size):
    return len(s) * size * CW


def txt(x, y, s, size=9.5, fill=MUT, weight=None, family=MONO, anchor=None):
    a = f' font-weight="{weight}"' if weight else ""
    b = f' text-anchor="{anchor}"' if anchor else ""
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}"'
            f' font-family="{family}"{a}{b}>{escape(s)}</text>')


def chip(x, y, w, h, title, lines=(), color=LAV, dashed=False, size=9.5):
    if w_of(title, 11.5) > w - 22:
        warn(f"titre hors chip ({w_of(title, 11.5):.0f} > {w - 22:.0f}): {title}")
    for ln in lines:
        if w_of(ln, size) > w - 22:
            warn(f"ligne hors chip ({w_of(ln, size):.0f} > {w - 22:.0f}): {ln}")
    dash = ' stroke-dasharray="4 3"' if dashed else ""
    o = [f'<rect x="{x:.0f}" y="{y:.0f}" width="{w:.0f}" height="{h:.0f}" rx="5" fill="{SURF}"'
         f' stroke="{color}" stroke-opacity="0.55" stroke-width="1"{dash}/>',
         f'<rect x="{x:.0f}" y="{y:.0f}" width="3" height="{h:.0f}" rx="1.5" fill="{color}"/>',
         txt(x + 11, y + 19, title, 11.5, TEXT, 600, SANS)]
    yy = y + 34
    for ln in lines:
        o.append(txt(x + 11, yy, ln, size, MUT))
        yy += size + 3.6
    return "\n".join(o)


def chip_h(lines, size=9.5):
    return 34 + len(lines) * (size + 3.6) + 4


def pane(x, y, w, h, color, label, sub=None, lab_w=None):
    if w_of(label, 13) > w - 36:
        warn(f"titre de panneau trop large: {label}")
    if sub and lab_w and w_of(sub, 9.5) > lab_w - 26:
        warn(f"sous-titre de panneau trop large ({w_of(sub, 9.5):.0f}): {sub}")
    o = [f'<rect x="{x:.0f}" y="{y:.0f}" width="{w:.0f}" height="{h:.0f}" rx="8" fill="{color}"'
         f' fill-opacity="0.06" stroke="{color}" stroke-width="1.2" stroke-opacity="0.75"/>',
         txt(x + 18, y + 26, label, 13, color, 700, SANS)]
    if sub:
        o.append(txt(x + 18, y + 44, sub, 9.5, MUT))
    return "\n".join(o)


def arrow(x1, y1, x2, y2, color=DIM, dash=False, label=None):
    d = ' stroke-dasharray="4 3"' if dash else ""
    out = (f'<path d="M {x1:.1f} {y1:.1f} L {x2:.1f} {y2:.1f}" fill="none" stroke="{color}"'
           f' stroke-width="1.3"{d} marker-end="url(#arw)"/>')
    if label:
        out += txt((x1 + x2) / 2, min(y1, y2) - 6, label, 9, DIM, anchor="middle")
    return out


def svg(w, h, label, body):
    w, h = int(round(w)), int(round(h))
    for m in re.finditer(r'<text x="([0-9.]+)" y="([0-9.]+)" font-size="([0-9.]+)"[^>]*>([^<]*)</text>', body):
        x_, y_, size_, c_ = float(m.group(1)), float(m.group(2)), float(m.group(3)), m.group(4)
        if x_ + w_of(c_, size_) > w - 10:
            warn(f"texte hors canevas a droite: {c_}")
        if y_ > h - 4:
            warn(f"texte sous le canevas: {c_}")
    for m in re.finditer(r'<rect x="([0-9.-]+)" y="([0-9.-]+)" width="([0-9.]+)" height="([0-9.]+)"', body):
        x_, y_, w_, h_ = (float(m.group(i)) for i in range(1, 5))
        if x_ + w_ > w - 2 or y_ + h_ > h - 2:
            warn(f"rect hors canevas (x={x_:.0f} y={y_:.0f} w={w_:.0f} h={h_:.0f})")
    defs = ('<defs><marker id="arw" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6"'
            ' markerHeight="6" orient="auto-start-reverse">'
            f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{DIM}"/></marker></defs>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}"'
            f' role="img" aria-label="{escape(label)}">\n{defs}\n'
            f'<rect x="0" y="0" width="{w}" height="{h}" rx="10" fill="{BASE}"/>\n{body}\n</svg>\n')


def grid(items, x0, y0, w_total, h, gap=12, color=LAV, title_size=11.5):
    """Range des chips sur une ligne, largeur repartie, retour du bloc + hauteur."""
    n = len(items)
    cw = (w_total - (n - 1) * gap) / n
    out = []
    for i, (t, lines) in enumerate(items):
        out.append(chip(x0 + i * (cw + gap), y0, cw, h, t, lines, color))
    return "\n".join(out)


# --------------------------------------------------------------- la carte
def d_map():
    W, M = 1240, 24
    out = [txt(M, 30, "the whole system on one page", 13, LAV, 700, SANS)]

    out.append(chip(M, 46, 210, 26, "the internet", (), DIM))
    out.append(txt(M + 222, 58, "one wildcard DNS record, both sides behind NAT", 9.5, MUT))
    out.append(arrow(M + 105, 76, M + 105, 106, LAV, label="DNS"))

    vy = 110
    vps = [("Pangolin", ["TLS, the only", "open port"]),
           ("Zitadel", ["login for every", "service"]),
           ("headscale", ["tailnet control"]),
           ("Stalwart", ["mail"]),
           ("Vaultwarden", ["passwords"])]
    out.append(pane(M, vy, W - 2 * M, 104, TEAL, "VPS", "the only public door"))
    out.append(grid(vps, M + 20, vy + 52, W - 2 * M - 40, 44, 12, TEAL))

    ty = vy + 104
    out.append(arrow(W / 2 - 120, ty + 12, W / 2 - 120, ty + 58, BLU, label="newt tunnel"))
    out.append(txt(W / 2 - 100, ty + 40, "tower dials out, nothing dials in", 9.5, MUT))

    hy = ty + 70
    services = [
        ("files, photos", ["nextcloud", "immich", "syncthing", "garage S3"]),
        ("code, docs", ["gitea", "wiki.js", "open-notebook", "anki sync"]),
        ("media", ["jellyfin", "navidrome", "arr stack", "audiobookshelf"]),
        ("talk", ["matrix + bridges", "gotify", "shlink", "stalwart client"]),
        ("plumbing", ["postgres", "ZFS + attic", "windmill", "k3s / rancher"]),
    ]
    ch = 88
    out.append(pane(M, hy, W - 2 * M, 20 + 52 + ch + 30, BLU, "tower",
                    "the machine at home carries everything else"))
    out.append(grid(services, M + 20, hy + 52, W - 2 * M - 40, ch, 12, BLU))
    out.append(txt(M + 20, hy + 52 + ch + 22,
                   "118 units running · 133 service modules · 36 public routes · one database per app",
                   9.5, MUT))

    oy = hy + 20 + 52 + ch + 30 + 14
    others = [("laptop", ["the only GPU"]),
              ("handheld", ["queue worker"]),
              ("phone", ["tunnels to the LAN"]),
              ("Mac", ["nix-darwin"])]
    out.append(pane(M, oy, W - 2 * M, 96, MAU, "the same flake elsewhere",
                    "same repo, same profiles, joined to the tailnet"))
    out.append(grid(others, M + 20, oy + 52, W - 2 * M - 40, 30, 12, MAU))
    return svg(W, oy + 96 + 18, "the whole system on one page", "\n".join(out))


# --------------------------------------------------------------- inventaire
def d_inventory():
    W, M = 1240, 24
    out = [txt(M, 30, "what actually runs, by job", 13, LAV, 700, SANS),
           txt(M, 48, "every line is a service folder in services/", 9.5, MUT)]
    groups = [
        ("identity", TEAL, ["zitadel  login for everything", "vaultwarden  passwords",
                            "hermes-broker  root access"]),
        ("edge", SKY, ["pangolin  TLS and routing", "newt  tunnels from home",
                       "headscale  tailnet", "adguard  DNS"]),
        ("files and photos", BLU, ["nextcloud  files, calendar", "immich  23k photos",
                                   "syncthing  device sync", "garage  S3 artifacts"]),
        ("code and knowledge", LAV, ["gitea  git hosting", "wiki.js  documentation",
                                     "open-notebook  research", "anki  flashcards"]),
        ("media", PEACH, ["jellyfin  video", "navidrome + octo  music",
                          "arr stack  acquisition", "audiobookshelf  audio"]),
        ("talk", MAU, ["matrix + 5 bridges", "stalwart  mail",
                       "gotify  notifications", "shlink  short links"]),
        ("orchestration", YEL, ["windmill  job queue", "k3s + rancher  console",
                                "jupyterhub  notebooks", "microvm  dev VMs"]),
        ("data and backups", GRN, ["postgres  one db per app", "ZFS  datasets, snapshots",
                                   "attic  binary cache", "pqbox  encrypted archives"]),
        ("access and control", PINK, ["kasm, novnc  remote desktop", "rustguac  gateway",
                                      "ttyd + zellij  terminal", "glances, zabbix, atop"]),
    ]
    cols, gap, ch = 3, 16, 92
    gw = (W - 2 * M - (cols - 1) * gap) / cols
    y, n = 70, 0
    for name, col, items in groups:
        c = n % cols
        x = M + c * (gw + gap)
        out.append(chip(x, y, gw, ch, name, items, col))
        n += 1
        if n % cols == 0:
            y += ch + gap
    return svg(W, y + (0 if n % cols == 0 else ch) + 22, "what actually runs", "\n".join(out))


# --------------------------------------------------------------- une requete
def d_request():
    W, M = 1240, 24
    out = [txt(M, 30, "opening cloud.marcpartensky.com", 13, LAV, 700, SANS),
           txt(M, 48, "no certificate and no open port on the machine at home", 9.5, MUT)]
    steps = [("browser", (), DIM, "you, anywhere"),
             ("*.marcpartensky.com", (), SKY, "wildcard DNS"),
             ("Pangolin", ("TLS",), TEAL, "on the VPS"),
             ("Zitadel", ("session?",), TEAL, "login or passkey"),
             ("newt", ("tunnel",), BLU, "tower dials out"),
             ("nextcloud", (), GRN, "loopback only")]
    gap, bh = 30, 66
    bw = (W - 2 * M - 5 * gap) / 6
    x, y = M, 80
    for i, (t, lines, col, sub) in enumerate(steps):
        out.append(chip(x, y, bw, bh, t, lines, col))
        out.append(txt(x + 11, y + bh + 16, sub, 9, DIM))
        if i < len(steps) - 1:
            out.append(arrow(x + bw + 4, y + bh / 2, x + bw + gap - 6, y + bh / 2, DIM))
        x += bw + gap
    ay = y + bh + 42
    out.append(pane(M, ay, W - 2 * M, 92, YEL, "same path, two ways to authenticate", None, lab_w=W))
    half = (W - 2 * M - 60) / 2
    out.append(chip(M + 20, ay + 22, half, 52, "the app speaks OIDC",
                    ["Zitadel logs the user in"], YEL))
    out.append(chip(M + 20 + half + 20, ay + 22, half, 52, "the app has no login",
                    ["Pangolin checks the session first"], YEL))
    return svg(W, ay + 92 + 18, "one request end to end", "\n".join(out))


# --------------------------------------------------------------- sauvegardes
def d_backup():
    W, M = 1240, 24
    out = [txt(M, 30, "backups: the machine holding the data keeps no copy", 13, LAV, 700, SANS)]
    top, cm = 52, 60
    cw = (W - 2 * M - 2 * cm) / 3
    cols = [
        ("tower", "holds the state", BLU, [
            ("postgres", ["nextcloud, gitea,", "zitadel, hermes"]),
            ("agent state", ["config, sessions,", "skills, plugins"]),
            ("fallback 05:00", ["skipped when a fresh", "archive exists"], YEL, True),
        ]),
        ("laptop", "pulls, at 03:10", TEAL, [
            ("its own timer", ["not the server's"]),
            ("stages locally", ["dumps and archive"]),
            ("encrypts here", ["the key never", "touches tower"]),
        ]),
        ("archives", "three tiers", GRN, [
            ("daily", ["yesterday, restorable", "in minutes"]),
            ("weekly", ["a month of history"]),
            ("manual", ["before a risky change"]),
        ]),
    ]
    bottom, x = top, M
    for name, sub, col, chips in cols:
        ph = 58 + sum(chip_h(c[1]) + 10 for c in chips) + 8
        out.append(pane(x, top, cw, ph, col, name, sub, lab_w=cw - 40))
        y = top + 58
        for c in chips:
            hh = chip_h(c[1])
            col_c = c[2] if len(c) > 2 else col
            out.append(chip(x + 16, y, cw - 32, hh, c[0], c[1], col_c, dashed=len(c) > 3))
            y += hh + 10
        if x + cw + cm <= W - M:
            out.append(arrow(x + cw + 8, top + 62, x + cw + cm - 6, top + 62, LAV))
        bottom = max(bottom, top + ph)
        x += cw + cm
    out.append(txt(M, bottom + 22, "encrypted with a post-quantum KEM before leaving the laptop", 9.5, MUT))
    return svg(W, bottom + 38, "backup pipeline", "\n".join(out))


# ------------------------------------------------------------------- agent
def d_agent():
    W, M = 1240, 24
    out = [txt(M, 30, "the agent: one gateway, real tools, one door to root", 13, LAV, 700, SANS)]
    top = 54
    sw = 240
    surf = ["matrix", "discord bot", "mobile app", "web ui", "desktop app"]
    out.append(pane(M, top, sw, 54 + len(surf) * 30 + 12, TEAL, "talks to you", None, lab_w=sw - 36))
    for i, t in enumerate(surf):
        out.append(chip(M + 16, top + 46 + i * 30, sw - 32, 24, t, (), TEAL))
    gw_x, gw_w = M + sw + 52, 230
    out.append(chip(gw_x, top + 60, gw_w, 54, "hermes-agent", ("one gateway,", "several profiles"), LAV))
    gm = top + 60 + 27
    out.append(arrow(M + sw + 4, gm, gw_x - 12, gm, LAV))
    tx = gw_x + gw_w + 52
    tw = W - M - tx
    tools = ["nextcloud  files, calendar", "gitea, shlink, mail",
             "browser with CDP", "anki, arr, media", "nix, git, ssh"]
    out.append(pane(tx, top, tw, 54 + len(tools) * 30 + 12, MAU, "can touch", None, lab_w=tw - 36))
    for i, t in enumerate(tools):
        out.append(chip(tx + 16, top + 46 + i * 30, tw - 32, 24, t, (), MAU))
    out.append(arrow(gw_x + gw_w + 4, gm, tx - 12, gm, LAV))
    by = top + 54 + len(surf) * 30 + 12 + 16
    out.append(pane(M, by, W - 2 * M, 76, RED, "root",
                    "no sudo: a broker, a password or passkey, a record", lab_w=W - 60))
    out.append(arrow(gw_x + gw_w / 2, by - 6, gw_x + gw_w / 2, by + 12, RED))
    out.append(txt(M + 20, by + 64, "the agent edits the same repo that defines the host, so rebuilds are gated and serialized", 9.5, DIM))
    return svg(W, by + 76 + 16, "the agent", "\n".join(out))


# -------------------------------------------------------------- 6. couche IA
def d_ai_layer():
    """La couche IA: harness, modeles, outils, privilege. Le coeur du repo."""
    W, M = 1240, 24
    out = [txt(M, 30, "the AI layer: a harness with 35 tool servers, and a bounded privilege", 13, LAV, 700, SANS)]
    top = 52
    surf = ["matrix", "discord bot", "mobile app", "web ui", "desktop app"]
    sw = (W - 2 * M - 4 * 10) / 5
    for i, s in enumerate(surf):
        out.append(chip(M + i * (sw + 10), top, sw, 24, s, (), TEAL))
    out.append(arrow(W / 2 - 40, top + 26, W / 2 - 40, top + 44, LAV))

    cy = top + 52
    cw = (W - 2 * M - 3 * 14) / 4
    cols = [
        ("the harness", LAV, [("hermes-agent 2026.9.24", ["one gateway", "3 profiles"]),
                              ("memory + skills", ["31 skills on demand", "sessions persisted"]),
                              ("scheduling", ["cron, webhooks,", "sub-agent delegation"])]),
        ("the models", TEAL, [("deepseek  default", ["1M context, vision"]),
                              ("openrouter  fallback", ["per task routes"]),
                              ("claude + 2 local", ["heavy reasoning,", "two LAN endpoints"])]),
        ("the tools", MAU, [("35 MCP servers", ["infra, apps, money,", "personal, OSINT"]),
                            ("two transports", ["local stdio,", "private network HTTP"]),
                            ("one process", ["8 servers, 90 tools,", "85 MB instead of 1.7 GB"])]),
        ("the privilege", RED, [("brokered", ["no sudo, no ambient", "credential"]),
                               ("gated", ["serialized rebuilds,", "pure evaluation"]),
                               ("audited", ["scope, rate limit,", "one record per call"])]),
    ]
    bottom = cy
    ph = 58 + max(sum(chip_h(c[1]) + 10 for c in chips) for _, _, chips in cols)
    for i, (name, col, chips) in enumerate(cols):
        x = M + i * (cw + 14)
        out.append(pane(x, cy, cw, ph, col, name, None, lab_w=cw - 30))
        y = cy + 46
        for c in chips:
            hh = chip_h(c[1])
            out.append(chip(x + 12, y, cw - 24, hh, c[0], c[1], col))
            y += hh + 10
        bottom = max(bottom, cy + ph)
    by = bottom + 14
    out.append(pane(M, by, W - 2 * M, 74, GRN, "same repo as the host",
                    "the agent edits the configuration it runs on, and cannot merge without a human"))
    out.append(txt(M + 18, by + 60, "every surface is a client of the same gateway: one brain, one state directory, one audit trail", 9.5, DIM))
    return svg(W, by + 74 + 16, "the AI layer", "\n".join(out))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, "svg")
    os.makedirs(out_dir, exist_ok=True)
    docs = {
        "map": d_map(),
        "inventory": d_inventory(),
        "request-path": d_request(),
        "backups": d_backup(),
        "agent": d_agent(),
        "ai-layer": d_ai_layer(),
    }
    for name, content in docs.items():
        p = os.path.join(out_dir, name + ".svg")
        with open(p, "w") as f:
            f.write(content)
        h = re.search(r'height="(\d+)"', content).group(1)
        print(f"{name:14} {h:>4} px  {len(content):6} octets")
    if WARN:
        print("\ndefauts geometriques:")
        for m in WARN:
            print("  -", m)
        raise SystemExit(1)
    print("\ngeometrie ok")


if __name__ == "__main__":
    main()
