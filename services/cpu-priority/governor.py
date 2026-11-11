#!/usr/bin/env python3
"""Gouverneur CPU des jobs winnie (declaration : services/cpu-priority/default.nix).

Principe
--------
Les plafonds CPUQuota declaratifs sont la valeur SURE (etat "capped"). Ce
gouverneur ne fait que les ELARGIR (etat "wide") quand la pression CPU de
user.slice (sessions de marc + sessions Hermes) reste quasi nulle pendant
2 minutes : a ce moment-la personne ne fait la queue pour du CPU et les
batches peuvent prendre la machine. Exception : les jobs navigateur (voir
HARD_CAP plus bas) restent plafonnes a 30 % du CPU total en permanence.
Des qu'une tache interactive attend du
CPU (some avg10 >= HIGH), on referme sur les plafonds declaratifs.

Pourquoi la PSI de user.slice et pas la PSI systeme : verifie le 25/10/2026,
le throttling CFS d'un cgroup remonte dans SA PSI (sonde 4 threads sous
CPUQuota=100 % : some avg10=23 %, full avg10=23 %) et donc dans la PSI
globale. Un batch plafonne se signalerait lui-meme comme "quelqu'un attend"
et les vannes ne s'ouvriraient jamais. Les unites winnie sont des unites
systeme (system.slice), les sessions de marc et de Hermes sont dans
user.slice : c'est le bon thermometre.

Les overrides sont poses avec `systemctl set-property --runtime` : ils vivent
dans /run et disparaissent au reboot. La config declarative reste la
reference, et si ce gouverneur s'arrete on reste borne (etat "capped").

Cout : un tick ne fait que lire deux fichiers (/proc-like) et n'appelle
`systemctl` que pour les unites dont le plafond change. Ne PAS revenir a
`systemctl list-units` ici : l'enumeration complete des unites coutait 1,1 s
de CPU par tick (mesure du 25/10/2026).

Usage : winnie-cpu-governor [--print] [--force wide|capped]
"""
import json
import os
import pathlib
import subprocess
import sys

# unite -> (plafond % en etat capped, plafond % en etat wide)
UNITS = {
    "ollama.service": (600, 1200),
    "winnie-calories.service": (400, 1200),
}
# Jobs navigateur winnie : plafond DUR de 30 % du total (480 % de 16 threads),
# jamais elargi (demande marc 25/10/2026). Reaffirme a chaque tick pour
# rattraper un override --runtime perime (ex. 400 % de l'ancien gouverneur).
HARD_CAP = {
    "winnie-gmaps-scrape.service": 480,
    "winnie-ingest-nightly.service": 480,
    "winnie-hours-refresh.service": 480,
}
JOB_UNITS = (400, 1200)  # unites transitoires winnie-job-* trouvees a l'execution

PRESSURE = pathlib.Path("/sys/fs/cgroup/user.slice/cpu.pressure")
SYSTEM_SLICE = pathlib.Path("/sys/fs/cgroup/system.slice")
HIGH = 10.0      # some avg10 (%) : des taches interactives font la queue
LOW = 2.0        # some avg10 (%) : personne n'attend
QUIET_TICKS = 8  # 8 ticks de 15 s = 2 min de calme avant d'elargir
STATE = pathlib.Path("/run/winnie-cpu-governor/state.json")


def pressure_some_avg10():
    """Pression CPU de user.slice, ou None si illisible (on restera borne)."""
    try:
        for line in PRESSURE.read_text().splitlines():
            if line.startswith("some"):
                for token in line.split():
                    if token.startswith("avg10="):
                        return float(token.split("=", 1)[1])
    except OSError:
        return None
    return None


def transient_units():
    """Unites winnie-job-* actives, via le repertoire cgroup (pas de systemctl)."""
    try:
        names = os.listdir(SYSTEM_SLICE)
    except OSError:
        return []
    return [n for n in names if n.startswith("winnie-job-") and n.endswith(".service")]


def read_state():
    try:
        data = json.loads(STATE.read_text())
        return data.get("state", "capped"), int(data.get("quiet", 0)), data.get("applied", {})
    except (OSError, ValueError):
        return "capped", 0, {}


def main():
    argv = sys.argv[1:]
    dry = "--print" in argv
    force = argv[argv.index("--force") + 1] if "--force" in argv else None

    psi = pressure_some_avg10()
    state, quiet, applied = read_state()

    if force in ("wide", "capped"):
        new_state, new_quiet = force, 0
    elif psi is None:
        new_state, new_quiet = "capped", 0
    elif state == "wide":
        new_state, new_quiet = ("capped" if psi > HIGH else "wide"), 0
    else:
        new_quiet = quiet + 1 if psi < LOW else 0
        new_state = "wide" if new_quiet >= QUIET_TICKS else "capped"
        if new_state == "wide":
            new_quiet = 0

    shown = "illisible" if psi is None else f"{psi:.2f}%"
    print(f"psi(user.slice) some avg10={shown} {state}({quiet}) -> {new_state}", flush=True)

    desired = {}
    for unit, (capped, wide) in UNITS.items():
        desired[unit] = wide if new_state == "wide" else capped
    for unit, quota in HARD_CAP.items():
        desired[unit] = quota
    for unit in transient_units():
        desired.setdefault(unit, JOB_UNITS[1] if new_state == "wide" else JOB_UNITS[0])

    if dry:
        for unit, quota in desired.items():
            print(f"  [dry-run] {unit}: {quota}%")
        return 0

    todo = {u: q for u, q in desired.items() if applied.get(u) != q or force is not None}
    for unit, quota in todo.items():
        subprocess.run(
            ["systemctl", "set-property", "--runtime", unit, f"CPUQuota={quota}%"],
            check=False, capture_output=True, timeout=15)
        applied[unit] = quota
    applied = {u: q for u, q in applied.items() if u in desired}

    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps({"state": new_state, "quiet": new_quiet, "applied": applied}) + "\n")
    if todo:
        print(f"  applique: {', '.join(f'{u}={q}%' for u, q in todo.items())}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
