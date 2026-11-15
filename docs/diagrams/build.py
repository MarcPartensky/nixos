#!/usr/bin/env python3
"""Genere les schemas SVG du README du repo nixos, dans le style des docs droplify.

Regles reprises de skill droplify-publishing/references/svg-doc-rendering.md :
- largeur monospace = len * font_size * 0.6, 8 % de marge dans les chips ;
- hauteurs de panneaux calculees, pas devinees ;
- fleches : 40 px de gap, pointe a 10 px de la boite visee ;
- aucun rgba() ni classe CSS : GitHub sanitise les SVG, on reste en
  presentation attributes (fill + fill-opacity, stroke, stroke-dasharray).
"""
from html import escape
import os
import re

BASE = "#1e1e2e"
SURF = "#313244"
TEXT = "#cdd6f4"
MUT = "#9399b2"
DIM = "#6c7086"
LAV = "#b4befe"
BLU = "#89b4fa"
TEAL = "#94e2d5"
GRN = "#a6e3a1"
YEL = "#f9e2af"
PEACH = "#fab387"
MAU = "#cba6f7"
RED = "#f38ba8"
PINK = "#f5c2e7"
SKY = "#89dceb"

WARN = []


def warn(msg):
    WARN.append(msg)


MONO = "ui-monospace, SFMono-Regular, Menlo, monospace"
SANS = "ui-sans-serif, system-ui, -apple-system, sans-serif"
CW = 0.6  # facteur de largeur monospace


def w_of(s, size):
    return len(s) * size * CW


def wrap(s, size, maxw):
    """Decoupe un texte en lignes qui tiennent dans maxw."""
    out, cur = [], ""
    for word in s.split():
        cand = (cur + " " + word).strip()
        if w_of(cand, size) <= maxw or not cur:
            cur = cand
        else:
            out.append(cur)
            cur = word
    if cur:
        out.append(cur)
    return out


def txt(x, y, s, size=9.5, fill=MUT, weight=None, family=MONO, anchor=None, opacity=None):
    a = f' font-weight="{weight}"' if weight else ""
    b = f' text-anchor="{anchor}"' if anchor else ""
    c = f' opacity="{opacity}"' if opacity is not None else ""
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}"'
            f' font-family="{family}"{a}{b}{c}>{escape(s)}</text>')


def chip(x, y, w, h, title, lines, color, dashed=False, size=9.5):
    if w_of(title, 11.5) > w - 22:
        warn(f"chip title overflow ({w_of(title, 11.5):.0f} > {w - 22:.0f}): {title}")
    for ln in lines:
        if w_of(ln, size) > w - 22:
            warn(f"chip line overflow ({w_of(ln, size):.0f} > {w - 22:.0f}): {ln}")
    dash = ' stroke-dasharray="4 3"' if dashed else ""
    o = [
        f'<rect x="{x:.0f}" y="{y:.0f}" width="{w:.0f}" height="{h:.0f}" rx="5"'
        f' fill="{SURF}" stroke="{color}" stroke-opacity="0.55" stroke-width="1"{dash}/>',
        f'<rect x="{x:.0f}" y="{y:.0f}" width="3" height="{h:.0f}" rx="1.5" fill="{color}"/>',
        txt(x + 11, y + 19, title, 11.5, TEXT, 600, SANS),
    ]
    yy = y + 34
    for ln in lines:
        o.append(txt(x + 11, yy, ln, size, MUT))
        yy += size + 3.6
    return "\n".join(o)


def chip_h(lines, size=9.5):
    return 34 + len(lines) * (size + 3.6) + 4


def pane(x, y, w, h, color, label, role=None, legend=None, lab_w=190):
    if w_of(label, 13) > w - 36:
        warn(f"pane title overflow: {label}")
    if role:
        for ln in (role if isinstance(role, list) else [role]):
            if w_of(ln, 9.5) > lab_w - 26:
                warn(f"pane role overflow ({w_of(ln, 9.5):.0f} > {lab_w - 26}): {ln}")
    o = [
        f'<rect x="{x:.0f}" y="{y:.0f}" width="{w:.0f}" height="{h:.0f}" rx="8"'
        f' fill="{color}" fill-opacity="0.06" stroke="{color}" stroke-width="1.2" stroke-opacity="0.75"/>',
        txt(x + 18, y + 26, label, 13, color, 700, SANS),
    ]
    if role:
        for i, ln in enumerate(role if isinstance(role, list) else [role]):
            o.append(txt(x + 18, y + 44 + i * 12, ln, 9.5, MUT))
    if legend:
        o.append(txt(x + w - 18, y + 26, legend, 9, DIM, None, MONO, anchor="end"))
    return "\n".join(o)


def arrow(x1, y1, x2, y2, color=DIM, dash=False, curved=None):
    d = f' stroke-dasharray="4 3"' if dash else ""
    if curved:
        path = f"M {x1:.1f} {y1:.1f} Q {curved[0]:.1f} {curved[1]:.1f} {x2:.1f} {y2:.1f}"
        return (f'<path d="{path}" fill="none" stroke="{color}" stroke-width="1.3"{d}'
                f' marker-end="url(#arw)"/>')
    return (f'<path d="M {x1:.1f} {y1:.1f} L {x2:.1f} {y2:.1f}" fill="none" stroke="{color}"'
            f' stroke-width="1.3"{d} marker-end="url(#arw)"/>')


def svg(w, h, label, body):
    w, h = int(round(w)), int(round(h))
    defs = (
        '<defs><marker id="arw" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6"'
        ' markerHeight="6" orient="auto-start-reverse">'
        f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{DIM}"/></marker>'
        '<marker id="arwl" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6"'
        ' markerHeight="6" orient="auto-start-reverse">'
        f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{LAV}"/></marker></defs>'
    )
    for m in re.finditer(r'<text x="([0-9.]+)" y="[0-9.]+" font-size="([0-9.]+)"[^>]*>([^<]*)</text>', body):
        x_, size_, content_ = float(m.group(1)), float(m.group(2)), m.group(3)
        right = x_ + w_of(content_, size_)
        if right > w - 10:
            warn(f"text past the canvas (x={x_:.0f} right={right:.0f} > {w - 10}): {content_}")
    for m in re.finditer(r'<rect x="([0-9.-]+)" y="([0-9.-]+)" width="([0-9.]+)" height="([0-9.]+)"', body):
        x_, y_, w_, h_ = (float(m.group(i)) for i in range(1, 5))
        if y_ + h_ > h - 2:
            warn(f"rect below the canvas (bottom={y_ + h_:.0f} > {h - 2}): y={y_:.0f} h={h_:.0f}")
        if x_ + w_ > w - 2:
            warn(f"rect past the canvas (right={x_ + w_:.0f} > {w - 2})")
    for m in re.finditer(r'<text x="[0-9.]+" y="([0-9.]+)"', body):
        if float(m.group(1)) > h - 4:
            warn(f"text below the canvas (y={m.group(1)} > {h - 4})")
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}"'
            f' role="img" aria-label="{escape(label)}">\n{defs}\n'
            f'<rect x="0" y="0" width="{w}" height="{h}" rx="10" fill="{BASE}"/>\n'
            f'{body}\n</svg>\n')


# ---------------------------------------------------------------- 1. planes
def d_planes():
    W = 1240
    planes = [
        ("Control plane", "no runtime configuration, ever", LAV, [
            ("one flake", ["every machine and every input", "pinned by revision"]),
            ("pure evaluation", ["no getEnv, no getFlake,", "no path outside the store"]),
            ("gated rebuild", ["serialized by a lock,", "impure refused for all"]),
            ("two speeds", ["structural change pays the", "evaluation, containers do not"]),
        ]),
        ("Identity plane", "checked before the app runs", TEAL, [
            ("one OIDC provider", ["services that speak OIDC", "authenticate themselves"]),
            ("proxy level SSO", ["apps without auth inherit", "it from the edge"]),
            ("brokered privilege", ["PAM password or passkey,", "scoped and audited"]),
            ("per machine keys", ["one age key per host:", "it decrypts only its own file"]),
        ]),
        ("Data plane", "lifecycle over storage", BLU, [
            ("database per app", ["role and database declared", "in the flake"]),
            ("object store", ["build artifacts and a", "mirror of phone photos"]),
            ("ZFS datasets", ["snapshots, capped cache,", "compressed swap first"]),
            ("backup tiers", ["daily, weekly, manual,", "encrypted post quantum"]),
        ]),
        ("Agent plane", "tools, not credentials", MAU, [
            ("one gateway", ["several surfaces and", "profiles, one process"]),
            ("one MCP host", ["all hand written servers,", "a single process"]),
            ("plugins by Nix", ["linked at activation,", "not installed by hand"]),
            ("one path to root", ["no sudo: the broker is", "the only door"]),
        ]),
    ]
    top, gap, lab, pad = 24, 16, 214, 18
    rows = []
    for name, role, col, chips in planes:
        ch_h = max(chip_h(c[1]) for c in chips)
        rows.append((name, role, col, chips, ch_h))
    h = top + sum(r[4] + 2 * pad for r in rows) + gap * (len(rows) - 1) + 24
    out, y = [], top
    for name, role, col, chips, ch_h in rows:
        ph = ch_h + 2 * pad
        out.append(pane(24, y, W - 48, ph, col, name, role, lab_w=lab))
        cw = (W - 48 - lab - 30 - 3 * 12) / 4
        x = 24 + lab
        for i, (t, lines) in enumerate(chips):
            out.append(chip(x, y + pad, cw, ch_h, t, lines, col))
            x += cw + 12
        y += ph + gap
    return svg(W, h, "the four planes of the platform", "\n".join(out))


# ------------------------------------------------------- 2. service contract
def d_contract():
    W = 1240
    steps = [
        ("1 module", ["package, dedicated user,", "unit file"], LAV),
        ("2 secret", ["sops file, materialized", "at activation"], TEAL),
        ("3 database", ["role and database", "provisioned by the flake"], BLU),
        ("4 route", ["hostname, target,", "protocol in Nix"], SKY),
        ("5 auth", ["SSO required, or the app", "authenticates itself"], YEL),
        ("6 URL", ["public under the wildcard,", "TLS at the edge only"], GRN),
    ]
    bw, bh, gap = 176, 116, 30
    top = 56
    out = [txt(24, 28, "the contract of a service: six declarations, no runtime surprises", 13, LAV, 700, SANS)]
    x = 24
    for i, (t, lines, col) in enumerate(steps):
        out.append(chip(x, top, bw, bh, t, lines, col))
        if i < len(steps) - 1:
            xa, ya = x + bw + 6, top + bh / 2
            out.append(arrow(xa, ya, xa + gap - 10, ya, LAV))
        x += bw + gap
    # bottom band: what the platform gives back
    by = top + bh + 34
    pn_w = W - 48
    out.append(pane(24, by, pn_w, 92, MUT, "what this buys",
                    "the same six declarations on every machine, human or agent", lab_w=pn_w - 40))
    facts = [
        "no port published to the internet anywhere",
        "no certificate outside the edge",
        "a new domain is a rebuild, not a click",
        "a forgotten declaration fails at evaluation",
    ]
    fx = 40
    for f in facts:
        out.append(txt(fx, by + 70, "· " + f, 9.5, MUT))
        fx += w_of("· " + f, 9.5) + 26
    return svg(W, by + 92 + 24, "the contract of a service", "\n".join(out))


# ---------------------------------------------------------- 3. request path
def d_request():
    W = 1240
    top = 64
    bh, gap = 108, 30
    bw = (W - 48 - 5 * gap) / 6
    boxes = [
        ("visitor", ["a browser, no", "certificate, no VPN"], MUT),
        ("wildcard DNS", ["every name resolves", "to the same edge"], SKY),
        ("edge: TLS", ["one certificate,", "one listening port"], LAV),
        ("identity check", ["session valid, or", "redirect to login"], TEAL),
        ("outbound tunnel", ["the data host dials", "out, never the reverse"], BLU),
        ("the app", ["HTTP on loopback,", "no public port"], GRN),
    ]
    out = [txt(24, 28, "one request, end to end", 13, LAV, 700, SANS),
           txt(24, 46, "identity is decided before the application is reached", 9.5, MUT)]
    x = 24
    for i, (t, lines, col) in enumerate(boxes):
        out.append(chip(x, top, bw, bh, t, lines, col))
        if i < len(boxes) - 1:
            xa, ya = x + bw + 6, top + bh / 2
            out.append(arrow(xa, ya, xa + gap - 10, ya, DIM))
        x += bw + gap
    # branch underneath
    by = top + bh + 46
    out.append(pane(24, by, W - 48, 96, YEL, "the branch that matters",
                    "does the application speak OIDC", lab_w=W - 60))
    half = (W - 48 - 60) / 2
    out.append(chip(42, by + 24, half, 54, "yes: the app authenticates itself",
                    ["it validates the session and keeps its own users"], YEL))
    out.append(chip(42 + half + 24, by + 24, half, 54, "no: the proxy enforces SSO",
                    ["the app never receives an unauthenticated request"], YEL))
    return svg(W, by + 96 + 24, "one request end to end", "\n".join(out))


# --------------------------------------------------------------- 4. backups
def d_backup():
    W = 1240
    top = 56
    cols = [
        ("data host", ["holds the state,", "runs the fallback"], LAV, [
            ("databases", ["one dump per app,", "taken locally"], BLU),
            ("agent state", ["config, sessions,", "skills, plugins"], MAU),
            ("fallback at 05:00", ["same pipeline,", "skipped if a fresh", "archive exists"], YEL, True),
        ]),
        ("producer machine", ["pulls, never pushed", "to, on its own timer"], TEAL, [
            ("03:10 timer", ["its own schedule,", "not the server's"], TEAL),
            ("local staging", ["dumps and archive", "written to its disk"], TEAL),
            ("encrypt here", ["the key never", "touches the server"], GRN),
        ]),
        ("several machines", ["a copy is not", "on one box"], BLU, [
            ("daily tier", ["yesterday, restorable", "in minutes"], GRN),
            ("weekly tier", ["a month of history", "with a slow path"], GRN),
            ("manual tier", ["before a risky", "change"], GRN),
        ]),
    ]
    cw = (W - 48 - 2 * 40 - 2 * 36) / 3
    out = [txt(24, 28, "backups where the producer is not the server", 13, LAV, 700, SANS),
           txt(24, 46, "a backup the compromised machine can delete is not a backup", 9.5, MUT)]
    x = 24
    bottom = top
    for name, role, col, chips in cols:
        inner = sum(chip_h(c[1]) + 12 for c in chips)
        ph = 62 + inner + 6
        out.append(pane(x, top, cw, ph, col, name, role, lab_w=cw - 40))
        y = top + 62
        for c in chips:
            hh = chip_h(c[1])
            out.append(chip(x + 16, y, cw - 32, hh, c[0], c[1], c[2], dashed=len(c) > 3))
            y += hh + 12
        if x + cw + 66 <= W - 24:
            out.append(arrow(x + cw + 10, top + ph / 2, x + cw + 66, top + ph / 2, LAV))
        bottom = max(bottom, top + ph)
        x += cw + 40 + 36
    return svg(W, int(bottom + 24), "backup pipeline", "\n".join(out))


# ----------------------------------------------------------------- 5. agent
def d_agent():
    W = 1240
    top = 56
    out = [txt(24, 28, "the agent plane: one brain, many surfaces, one door to root", 13, LAV, 700, SANS),
           txt(24, 46, "every surface is a client of the same gateway, tools are code", 9.5, MUT)]
    # surfaces column
    sw = 300
    surf = [("Matrix", "rooms and DMs"), ("Discord bot", "via the API server"),
            ("mobile app", "Pocket backend"), ("web UI", "isolated profile"),
            ("desktop app", "same state dir")]
    surv_h = 58 + len(surf) * 36 + 10
    out.append(pane(24, top, sw, surv_h, TEAL, "surfaces", "clients, not deployments", lab_w=sw - 40))
    for i, (t, d) in enumerate([
        ("Matrix", "rooms and DMs"),
        ("Discord bot", "via the API server"),
        ("mobile app", "Pocket backend"),
        ("web UI", "isolated profile"),
        ("desktop app", "same state dir"),
    ]):
        out.append(chip(40, top + 58 + i * 36, sw - 32, 30, t, [], TEAL) .replace(
            f'<text x="51" y="{top + 58 + i * 36 + 19:.1f}"', f'<text x="51" y="{top + 58 + i * 36 + 20:.1f}"'))
        out.append(txt(40 + sw - 32 - 11, top + 58 + i * 36 + 20, d, 9, DIM, None, MONO, anchor="end"))
    # gateway
    gw_x, gw_w = 24 + sw + 44, 300
    gw_y = top + 20
    out.append(chip(gw_x, gw_y, gw_w, 74, "hermes-agent gateway",
                    ["one process, several profiles", "state under /var/lib/hermes"], LAV))
    gw_mid = gw_y + 37
    out.append(arrow(24 + sw + 8, gw_mid, gw_x - 12, gw_mid, LAV))
    # tools column
    tx = gw_x + gw_w + 44
    tw = W - 24 - tx
    tools_def = [
        ("MCP host", ["all hand written MCP servers in one process,", "restarted by the flake or hot reloaded"]),
        ("plugins", ["Matrix reactions, Gotify bridge, pane reporting,", "packaged by Nix and linked at activation"]),
        ("host tools", ["git, nix, browsers, mail, calendar, files"]),
    ]
    host_h = 58 + sum(chip_h(l) + 12 for _, l in tools_def)
    out.append(pane(tx, top, tw, host_h, MAU, "host integration", "everything the agent can touch", lab_w=tw - 40))
    y = top + 58
    for t, lines in tools_def:
        hh = chip_h(lines)
        out.append(chip(tx + 16, y, tw - 32, hh, t, lines, MAU))
        y += hh + 12
    out.append(arrow(gw_x + gw_w + 8, gw_mid, tx - 12, gw_mid, LAV))
    # broker row
    by = top + max(surv_h, host_h) + 24
    out.append(pane(24, by, W - 48, 74, RED, "the only path to root",
                    "no ambient privilege, every request is a record", lab_w=W - 60))
    out.append(chip(42, by + 20, 520, 34, "hermes-broker", [], RED))
    out.append(txt(42 + 12 + w_of("hermes-broker", 11.5) + 16, by + 41,
                   "PAM password or WebAuthn passkey, scoped, rate limited, audited", 9, MUT))
    out.append(chip(W - 24 - 260, by + 20, 238, 34, "root on the host", [], RED))
    return svg(W, by + 74 + 24, "the agent plane", "\n".join(out))


# ---------------------------------------------------- 6. change / two speeds
def d_change():
    W = 1240
    out = [txt(24, 28, "two deployment speeds, chosen per service", 13, LAV, 700, SANS),
           txt(24, 46, "an image bump should not cost what a structural change costs", 9.5, MUT)]
    # lane A
    ay = 68
    out.append(pane(24, ay, W - 48, 150, LAV, "structural change",
                    "anything the flake has to know about", lab_w=W - 60))
    steps = [("edit", "a module"), ("pure check", "linter"), ("evaluate", "derivation only"),
             ("gate", "lock, no impure"), ("activate", "units, secrets"), ("cache", "build hook")]
    bw, gap = 168, 26
    x = 42
    for i, (t, d) in enumerate(steps):
        out.append(chip(x, ay + 62, bw, 40, t, [], LAV))
        out.append(txt(x + 11, ay + 118, d, 9, DIM))
        if i < len(steps) - 1:
            out.append(arrow(x + bw + 4, ay + 82, x + bw + gap - 6, ay + 82, LAV))
        x += bw + gap
    # lane B
    by = ay + 150 + 18
    out.append(pane(24, by, W - 48, 120, GRN, "container change",
                    "an image tag or an environment variable", lab_w=W - 60))
    steps2 = [("edit containers.nix", "declarative, but outside the host config"),
              ("render quadlet", "systemd unit generated"),
              ("restart unit", "seconds, no evaluation")]
    x = 42
    for i, (t, d) in enumerate(steps2):
        out.append(chip(x, by + 62, 300, 34, t, [], GRN))
        out.append(txt(x + 11, by + 112, d, 9, DIM))
        if i < len(steps2) - 1:
            out.append(arrow(x + 304, by + 79, x + 304 + 22, by + 79, GRN))
        x += 300 + 34
    return svg(W, by + 120 + 24, "two deployment speeds", "\n".join(out))


def main():
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "svg")
    os.makedirs(out_dir, exist_ok=True)
    docs = {
        "planes": d_planes(),
        "service-contract": d_contract(),
        "request-path": d_request(),
        "backups": d_backup(),
        "agent": d_agent(),
        "change-flow": d_change(),
    }
    for name, content in docs.items():
        p = os.path.join(out_dir, name + ".svg")
        with open(p, "w") as f:
            f.write(content)
        print(f"{name:18} {len(content):6} octets  {p}")
    if WARN:
        print("\nDEFauts geometriques:")
        for wmsg in WARN:
            print("  -", wmsg)
        raise SystemExit(1)
    print("\ngeometrie: aucun debordement detecte")


if __name__ == "__main__":
    main()
