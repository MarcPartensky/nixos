"""Presence de marc (travail / sommeil / machine) pour la porte `needs_absence`.

Le dispatcher taskq garde une porte : une tache `needs_absence` ne tourne que
si marc n'utilise pas la machine. Historiquement la porte etait REACTIVE
("aucune interaction depuis TASKQ_ABSENCE_MINUTES"). Ce module ajoute le
modele PREVISIONNEL demande par marc : des fenetres de sommeil et de travail
declarees (fichier /etc/taskq/presence.json, ecrit par le module Nix), croisees
avec les signaux reels (cpu des process de marc, tty actif, activite hermes ou
webui), pour deviner sa presence meme quand il discute depuis son telephone au
bureau (une interaction ne prouve pas qu'il est devant tower).

Etats calcules :
  at_tower    machine utilisee a l'instant (cpu marc eleve ou shell recent) :
              une tache de fond doit se mettre en pause
  away_work   fenetre de travail (lun-ven) et machine au repos : marc est au
              bureau ; ses messages depuis un autre appareil ne comptent pas
  away_sleep  fenetre de sommeil et aucune interaction recente : il dort
  nearby      hors fenetre, machine au repos : la regle reactive (15 min sans
              interaction) decide

Overrides par date (table `state`, cle `presence_overrides`) : kind "off"
(jour libre) ou "wfh" (teletravail) suppriment la fenetre de travail du jour
concerne ; le sommeil n'a pas d'override en v1.

Tests (sans toucher a la base) :
  python3 presence.py --at '2026-10-26T10:30:00' --json
  python3 presence.py --at '2026-10-26T03:00:00' --busy
  TASKQ_PRESENCE_FAKE_NOW=... est aussi lu par now_local(), ce qui permet de
  rejouer un dry-run du dispatcher a une heure simulee.
"""

from __future__ import annotations

import copy
import datetime as dt
import json
import os

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - python < 3.9
    ZoneInfo = None  # type: ignore

DEFAULT_CONFIG = {
    "tz": "America/New_York",
    "sleep": {"start": "02:30", "end": "08:30"},
    "work": {"days": [1, 2, 3, 4, 5], "start": "09:00", "end": "18:30"},
}
CONFIG_PATH = os.environ.get("TASKQ_PRESENCE_CONFIG", "/etc/taskq/presence.json")
OVERRIDE_KINDS = ("off", "wfh")
DAY_NAMES = ["lun", "mar", "mer", "jeu", "ven", "sam", "dim"]


def load_config(path: str | None = None) -> dict:
    """Config declarative ; retombe sur DEFAULT_CONFIG si le fichier manque.

    Un fichier partiel se superpose aux defauts cle par cle : le module Nix
    peut n'ecrire que ce qu'il veut surcharger.
    """
    cfg = copy.deepcopy(DEFAULT_CONFIG)
    try:
        with open(path or CONFIG_PATH, encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return cfg
    if isinstance(raw, dict):
        if isinstance(raw.get("tz"), str):
            cfg["tz"] = raw["tz"]
        for key in ("sleep", "work"):
            if isinstance(raw.get(key), dict):
                cfg[key].update(raw[key])
    return cfg


def tz_of(cfg: dict) -> dt.tzinfo:
    if ZoneInfo is None:  # pragma: no cover
        return dt.timezone.utc
    try:
        return ZoneInfo(cfg.get("tz") or DEFAULT_CONFIG["tz"])
    except Exception:
        return ZoneInfo(DEFAULT_CONFIG["tz"])


def now_local(cfg: dict) -> dt.datetime:
    """Maintenant dans le fuseau de la config.

    TASKQ_PRESENCE_FAKE_NOW (ISO) force l'instant : tests seulement, pour
    rejouer un dry-run du dispatcher a une heure simulee.
    """
    tz = tz_of(cfg)
    fake = os.environ.get("TASKQ_PRESENCE_FAKE_NOW")
    if fake:
        try:
            parsed = dt.datetime.fromisoformat(fake)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=tz)
            return parsed.astimezone(tz)
        except ValueError:
            pass
    return dt.datetime.now(tz)


def _hhmm(value: str) -> dt.time:
    h, m = str(value).split(":")[:2]
    return dt.time(int(h), int(m))


def windows_on(cfg: dict, overrides: dict, day: dt.date) -> list[tuple]:
    """Fenetres (kind, debut, fin) qui COMMENCENT ce jour-la.

    Le sommeil est quotidien ; le travail respecte `days` (1 = lundi) et une
    date marquee "off" ou "wfh" n'a pas de fenetre de travail.
    """
    tz = tz_of(cfg)
    out: list[tuple] = []
    sleep = cfg["sleep"]
    out.append(("sleep",
                dt.datetime.combine(day, _hhmm(sleep["start"]), tz),
                dt.datetime.combine(day, _hhmm(sleep["end"]), tz)))
    work = cfg["work"]
    kind_override = (overrides.get(day.isoformat()) or {}).get("kind")
    days = {int(d) for d in work.get("days", [])}
    if day.isoweekday() in days and kind_override not in OVERRIDE_KINDS:
        out.append(("work",
                    dt.datetime.combine(day, _hhmm(work["start"]), tz),
                    dt.datetime.combine(day, _hhmm(work["end"]), tz)))
    return out


def window_at(cfg: dict, overrides: dict, now: dt.datetime) -> tuple:
    """(kind, fin) de la fenetre active a `now`, ou (None, None).

    On regarde aussi la veille : une fenetre commencee hier peut courir
    aujourd'hui.
    """
    for back in (1, 0):
        day = (now + dt.timedelta(days=back)).date()
        for kind, start, end in windows_on(cfg, overrides, day):
            if start <= now < end:
                return kind, end
    return None, None


def verdict(cfg: dict, overrides: dict, now: dt.datetime,
            busy: bool, tty_why: str | None,
            connected: bool, connected_why: str) -> dict:
    """L'etat de presence a `now`, croise avec les signaux reels.

    busy/tty_why = signaux d'UTILISATION de tower (cpu de marc, shell actif) ;
    connected = interaction recente par n'importe quel canal (la partie
    prudente : erreur de lecture => connecte).
    """
    kind, until = window_at(cfg, overrides, now)
    until_iso = until.isoformat() if until else None
    if busy or tty_why:
        return {"state": "at_tower",
                "why": tty_why or "cpu de marc eleve",
                "window": kind, "until": until_iso, "absent_confident": False}
    if kind == "work":
        why = "fenetre travail"
        if connected:
            why += " (interaction via un autre appareil, ignoree pour la porte)"
        return {"state": "away_work", "why": why,
                "window": kind, "until": until_iso, "absent_confident": True}
    if kind == "sleep":
        if connected:
            return {"state": "nearby",
                    "why": f"fenetre sommeil mais {connected_why}",
                    "window": kind, "until": until_iso, "absent_confident": False}
        return {"state": "away_sleep", "why": "fenetre sommeil, machine au repos",
                "window": kind, "until": until_iso, "absent_confident": True}
    return {"state": "nearby", "why": connected_why or "machine au repos",
            "window": None, "until": None, "absent_confident": False}


def may_start(state: str | None, absent_confident: bool, connected: bool,
              calm_seconds: float | None, calm_needed: int) -> tuple[bool, str]:
    """La porte `needs_absence` a l'instant : (peut demarrer, raison).

    `calm_seconds` = secondes depuis la derniere activite de marc sur tower
    (None = jamais vue depuis le demarrage du dispatcher : repute calme). La
    fenetre exige CALME + fenetre : un marc actif sur la machine bloque meme
    pendant une fenetre (jour de teletravail non declare, par exemple).
    """
    if state == "at_tower":
        return False, "marc utilise tower"
    if absent_confident:
        if calm_seconds is not None and calm_seconds < calm_needed:
            return False, (f"fenetre d'absence mais activite recente de marc "
                           f"({int(calm_seconds)} s)")
        return True, "marc absent (fenetre)"
    if not connected:
        return True, "marc absent (aucune interaction recente)"
    return False, "marc actif (interaction recente)"


def must_stop(state: str | None, absent_confident: bool,
              connected: bool) -> tuple[bool, str]:
    """Faut-il interrompre une tache `needs_absence` en cours : (oui, raison).

    Pendant une fenetre d'absence confirmee, seul l'usage reel de la machine
    (at_tower, deja calcule) interrompt : un message depuis le telephone au
    bureau ne coupe pas un job. Hors fenetre, la regle reactive d'origine
    s'applique : la premiere interaction le coupe.
    """
    if state == "at_tower":
        return True, "marc utilise tower"
    if not absent_confident and connected:
        return True, "marc est revenu (interaction recente)"
    return False, ""


def transitions(cfg: dict, overrides: dict, now: dt.datetime,
                count: int = 6) -> list[tuple]:
    """Les prochaines bornes de fenetres : [(quand, 'debut travail'), ...]."""
    events: list[tuple] = []
    for ahead in range(-1, 8):
        day = (now + dt.timedelta(days=ahead)).date()
        for kind, start, end in windows_on(cfg, overrides, day):
            for at, label in ((start, f"debut {kind}"), (end, f"fin {kind}")):
                if at > now:
                    events.append((at, label))
    events.sort(key=lambda item: item[0])
    return events[:count]


def resolve_day(cfg: dict, token: str, now: dt.datetime | None = None) -> dt.date:
    """today | demain | tomorrow | YYYY-MM-DD -> date (fuseau de la config)."""
    now = now or now_local(cfg)
    token = (token or "").strip().lower()
    if token in ("today", "aujourd'hui", "aujourdhui"):
        return now.date()
    if token in ("tomorrow", "demain"):
        return now.date() + dt.timedelta(days=1)
    return dt.date.fromisoformat(token)


def _main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="probe de presence (tests)")
    ap.add_argument("--at", help="instant simule (ISO), force FAKE_NOW")
    ap.add_argument("--busy", action="store_true", help="simule cpu marc eleve")
    ap.add_argument("--tty", metavar="RAISON", help="simule un shell marc actif")
    ap.add_argument("--connected", action="store_true",
                    help="simule une interaction hermes recente")
    ap.add_argument("--config", help="chemin du presence.json")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--transitions", action="store_true")
    args = ap.parse_args()
    if args.at:
        os.environ["TASKQ_PRESENCE_FAKE_NOW"] = args.at
    cfg = load_config(args.config)
    now = now_local(cfg)
    v = verdict(cfg, {}, now, args.busy, args.tty, args.connected,
                "interaction simulee")
    if args.json:
        print(json.dumps({"at": now.isoformat(timespec="seconds"),
                          **v}, indent=2, ensure_ascii=False))
    else:
        print(f"{now.isoformat(timespec='seconds')} presence={v['state']} "
              f"({v['why']})" + (f" jusqu'a {v['until']}" if v["until"] else ""))
    if args.transitions:
        for at, label in transitions(cfg, {}, now):
            print(f"  {DAY_NAMES[at.weekday()]} {at:%Y-%m-%d %H:%M} {label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
