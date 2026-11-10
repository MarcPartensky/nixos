#!/usr/bin/env python3
"""Pics de CPU par process, lus dans un log atop.

atop écrit un échantillon toutes les N secondes (10 s sur tower) dans un fichier
journalier rejouable. Ce script rejoue le log en format parsable (`atop -P PRC`)
et calcule le CPU consommé PENDANT chaque intervalle :

  - utime/stime de PRC sont CUMULÉS depuis le démarrage du process, donc on
    soustrait le même pid de l'échantillon précédent ;
  - un process mort pendant l'intervalle (état E, accounting noyau atopacct)
    n'a pas d'historique : la valeur PRC est déjà celle de l'intervalle ;
  - le pourcentage se normalise par l'intervalle (`ticks / hertz / interval`),
    sinon le pas d'échantillonnage gonfle tout d'un facteur N ;
  - seules les lignes `is_process = y` sont gardées (PRC liste aussi chaque
    thread, qui serait compté deux fois).

Sortie exprimée en % d'un seul cœur (100 % = 1 cœur saturé). Avec le
regroupement par nom (défaut), les pids portant le même nom sont SOMMÉS : une
grappe de serveurs MCP apparaît comme une ligne, pas comme vingt.

Exemples :
  atop-peaks                                  # log du jour, tout
  atop-peaks -b 13:00 -e 14:30                # fenêtre horaire
  atop-peaks -f hermes                        # process dont le nom matche
  atop-peaks -r /var/log/atop/atop_20261109    # un jour précis
  atop-peaks --timeline                        # total par échantillon
  atop-peaks --group pid                       # ne pas agréger par nom
"""

import argparse
import collections
import dataclasses
import os
import re
import subprocess
import sys

DEFAULT_LOGDIR = "/var/log/atop"


@dataclasses.dataclass
class Group:
    """CPU cumulé d'une clé d'agrégation sur un échantillon."""

    pct: float = 0.0
    pids: list[int] = dataclasses.field(default_factory=list)
    state: str = ""


def latest_log(logdir):
    files = [f for f in os.listdir(logdir) if re.fullmatch(r"atop_\d{8}", f)]
    if not files:
        sys.exit(f"aucun log atop dans {logdir}")
    return os.path.join(logdir, max(files))


def read_samples(logfile, begin, end, atop):
    """[(heure, {pid: (nom, ticks cumulés, hertz, état, intervalle)})]."""
    cmd = [atop, "-P", "PRC", "-r", logfile]
    if begin:
        cmd += ["-b", begin]
    if end:
        cmd += ["-e", end]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"atop a échoué : {proc.stderr.strip()[:400]}")

    samples = []
    cur_epoch = None
    cur_time = None
    cur = {}
    for line in proc.stdout.splitlines():
        if not line.startswith("PRC "):
            continue
        f = line.split()
        # PRC host epoch date time interval pid (name) state hertz utime stime
        #     nice prio rtprio policy curcpu sleepavg tgid is_process ...
        if len(f) < 20:
            continue
        if f[2] != cur_epoch:
            if cur_epoch is not None:
                samples.append((cur_time, cur))
            cur_epoch, cur_time, cur = f[2], f[4], {}
        if f[19] != "y":  # thread : déjà compté dans la ligne du process
            continue
        try:
            pid = int(f[6])
            ticks = int(f[10]) + int(f[11])
            entry = (f[7].strip("()"), ticks, int(f[9]) or 100, f[8], int(f[5]) or 1)
        except (ValueError, IndexError):
            continue
        cur[pid] = entry
    if cur_epoch is not None:
        samples.append((cur_time, cur))
    return samples


def per_interval(samples):
    """[(heure, {pid: (nom, % d'un cœur, état)})]."""
    out = []
    prev = {}
    for ts, snap in samples:
        row = {}
        for pid, (name, ticks, hertz, state, interval) in snap.items():
            old = prev.get(pid)
            delta = ticks - old if old is not None and ticks >= old else ticks
            row[pid] = (name, delta / hertz / interval * 100.0, state)
        out.append((ts, row))
        prev = {p: v[1] for p, v in snap.items() if v[3] != "E"}
    return out


def main():
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("-r", "--logfile", help="log atop (défaut : le plus récent)")
    ap.add_argument("-b", "--begin", help="début HH:MM")
    ap.add_argument("-e", "--end", help="fin HH:MM")
    ap.add_argument("-n", "--top", type=int, default=12, help="lignes affichées")
    ap.add_argument("-f", "--filter", help="regex sur le nom du process")
    ap.add_argument(
        "--group",
        choices=["pid", "name"],
        default="name",
        help="agréger par nom (défaut) ou par pid",
    )
    ap.add_argument("--timeline", action="store_true", help="total CPU par échantillon")
    ap.add_argument("--atop", default="atop", help="binaire atop")
    args = ap.parse_args()

    logfile = args.logfile or latest_log(DEFAULT_LOGDIR)
    samples = read_samples(logfile, args.begin, args.end, args.atop)
    if len(samples) < 3:
        sys.exit(f"moins de trois échantillons exploitables dans {logfile}")

    rows = per_interval(samples)
    pat = re.compile(args.filter) if args.filter else None

    def grouped(row):
        """Somme par clé (le nom agrège ses pids, `--group pid` ne le fait pas)."""
        out: dict[object, Group] = {}
        for pid, (name, pct, state) in row.items():
            if pat and not pat.search(name):
                continue
            key = pid if args.group == "pid" else name
            g = out.setdefault(key, Group())
            g.pct += pct
            g.pids.append(pid)
            g.state = state
        return out

    g_rows = [(ts, grouped(row)) for ts, row in rows[1:]]
    totals = [(ts, sum(g.pct for g in grp.values())) for ts, grp in g_rows]
    peak_ts, peak_total = max(totals, key=lambda kv: kv[1])

    print(f"log      : {logfile}")
    print(f"fenêtre  : {rows[0][0]} -> {rows[-1][0]}  ({len(rows)} échantillons)")
    print(
        f"pic total: {peak_total:.0f} % d'un cœur "
        f"({peak_total / 100:.1f} cœurs) à {peak_ts}"
    )

    if args.timeline:
        print("\ntimeline (total % d'un cœur, 100 = 1 cœur)")
        for ts, tot in totals:
            print(f"  {ts}  {tot:7.0f} %  {'#' * min(60, int(tot / 50))}")

    peak_row = dict(g_rows)[peak_ts]
    print(f"\nau pic ({peak_ts}) :")
    for key, g in sorted(peak_row.items(), key=lambda kv: -kv[1].pct)[: args.top]:
        if g.pct < 0.5:
            break
        who = " ".join(str(p) for p in g.pids[:4]) + ("…" if len(g.pids) > 4 else "")
        print(f"  {g.pct:7.0f} %  {str(key):22s} pid {who:<18} {g.state}")

    per = collections.defaultdict(
        lambda: {"peak": 0.0, "peak_ts": "", "sum": 0.0, "n": 0, "pids": []}
    )
    for ts, grp in g_rows:
        for key, g in grp.items():
            e = per[key]
            e["sum"] += g.pct
            e["n"] += 1
            if g.pct > e["peak"]:
                e.update(peak=g.pct, peak_ts=ts, pids=g.pids)

    print(f"\nclassement par pic ({args.group}, moyenne sur {len(g_rows)} intervalles) :")
    print(f"  {'pic %':>7} {'moy %':>7} {'nom':22s} {'pids':>7}  pic à")
    for key, e in sorted(per.items(), key=lambda kv: -kv[1]["peak"])[: args.top]:
        print(
            f"  {e['peak']:7.0f} {e['sum'] / max(1, e['n']):7.1f} {str(key):22s}"
            f" {len(e['pids']):>7}  {e['peak_ts']}"
        )


if __name__ == "__main__":
    main()
