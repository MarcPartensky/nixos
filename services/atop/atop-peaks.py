#!/usr/bin/env python3
"""CPU peaks per process, read from an atop log.

atop writes a sample every N seconds (10 s on tower) into a replayable
daily file. This script replays the log in parsable format (`atop -P PRC`)
and computes the CPU consumed DURING each interval:

  - utime/stime of PRC are CUMULATIVE since process start, so we
    subtract the same pid of the previous sample;
  - a process that died during the interval (state E, atopacct kernel
    accounting) has no history: the PRC value is already that of the interval;
  - the percentage is normalized by the interval (`ticks / hertz / interval`),
    otherwise the sampling step inflates everything by a factor N;
  - only the lines `is_process = y` are kept (PRC also lists each
    thread, which would be counted twice).

Output expressed in % of a single core (100 % = 1 saturated core). With the
grouping by name (default), the pids carrying the same name are SUMMED: a
cluster of MCP servers appears as one line, not as twenty.

Examples:
  atop-peaks                                  # today's log, everything
  atop-peaks -b 13:00 -e 14:30                # time window
  atop-peaks -f hermes                        # process whose name matches
  atop-peaks -r /var/log/atop/atop_20261109    # a precise day
  atop-peaks --timeline                        # total per sample
  atop-peaks --group pid                       # do not aggregate by name
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
    """Cumulative CPU of an aggregation key over a sample."""

    pct: float = 0.0
    pids: list[int] = dataclasses.field(default_factory=list)
    state: str = ""


def latest_log(logdir):
    files = [f for f in os.listdir(logdir) if re.fullmatch(r"atop_\d{8}", f)]
    if not files:
        sys.exit(f"no atop log in {logdir}")
    return os.path.join(logdir, max(files))


def read_samples(logfile, begin, end, atop):
    """[(time, {pid: (name, cumulative ticks, hertz, state, interval)})]."""
    cmd = [atop, "-P", "PRC", "-r", logfile]
    if begin:
        cmd += ["-b", begin]
    if end:
        cmd += ["-e", end]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"atop failed: {proc.stderr.strip()[:400]}")

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
        if f[19] != "y":  # thread: already counted in the process line
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
    """[(time, {pid: (name, % of a core, state)})]."""
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
    ap.add_argument("-r", "--logfile", help="atop log (default: the most recent)")
    ap.add_argument("-b", "--begin", help="start HH:MM")
    ap.add_argument("-e", "--end", help="end HH:MM")
    ap.add_argument("-n", "--top", type=int, default=12, help="lines displayed")
    ap.add_argument("-f", "--filter", help="regex on the process name")
    ap.add_argument(
        "--group",
        choices=["pid", "name"],
        default="name",
        help="aggregate by name (default) or by pid",
    )
    ap.add_argument("--timeline", action="store_true", help="total CPU per sample")
    ap.add_argument("--atop", default="atop", help="atop binary")
    args = ap.parse_args()

    logfile = args.logfile or latest_log(DEFAULT_LOGDIR)
    samples = read_samples(logfile, args.begin, args.end, args.atop)
    if len(samples) < 3:
        sys.exit(f"fewer than three usable samples in {logfile}")

    rows = per_interval(samples)
    pat = re.compile(args.filter) if args.filter else None

    def grouped(row):
        """Sum per key (the name aggregates its pids, `--group pid` does not)."""
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
    print(f"window   : {rows[0][0]} -> {rows[-1][0]}  ({len(rows)} samples)")
    print(
        f"peak total: {peak_total:.0f} % of a core "
        f"({peak_total / 100:.1f} cores) at {peak_ts}"
    )

    if args.timeline:
        print("\ntimeline (total % of a core, 100 = 1 core)")
        for ts, tot in totals:
            print(f"  {ts}  {tot:7.0f} %  {'#' * min(60, int(tot / 50))}")

    peak_row = dict(g_rows)[peak_ts]
    print(f"\nat peak ({peak_ts}):")
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

    print(f"\nranking by peak ({args.group}, average over {len(g_rows)} intervals):")
    print(f"  {'peak %':>7} {'avg %':>7} {'name':22s} {'pids':>7}  peak at")
    for key, e in sorted(per.items(), key=lambda kv: -kv[1]["peak"])[: args.top]:
        print(
            f"  {e['peak']:7.0f} {e['sum'] / max(1, e['n']):7.1f} {str(key):22s}"
            f" {len(e['pids']):>7}  {e['peak_ts']}"
        )


if __name__ == "__main__":
    main()
