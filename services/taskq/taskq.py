#!/usr/bin/env python3
"""taskq CLI : poser, lire et piloter les taches lourdes de tower.

  taskq unit winnie-gmaps-scrape --class heavy --llm paid --mem 3000 --est 120
  taskq run 'cargo build --release' --workdir /home/marc/git/winnie/backend --class medium
  taskq list --status queued
  taskq why 12                 # pourquoi cette tache tourne ou pas
  taskq metrics                # etat machine vu par le dispatcher
  taskq presence               # fenetres sommeil/travail + overrides (off/wfh)
  taskq digest --ack           # resume pour marc, marque les decisions comme notifiees
  taskq pause | resume
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys

import presence

DB = "postgresql://taskq@127.0.0.1/taskq"


def psql(sql: str, tuples: bool = True) -> str:
    args = ["psql", DB, "-v", "ON_ERROR_STOP=1", "-q"] + (["-tA"] if tuples else []) + ["-c", sql]
    out = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        print(out.stderr.strip(), file=sys.stderr)
        sys.exit(1)
    return out.stdout.strip()


def q(v) -> str:
    return "null" if v is None else "'" + str(v).replace("'", "''") + "'"


def rows(sql: str) -> list[dict]:
    txt = psql(sql)
    return json.loads(txt) if txt else []


def jrows(sql: str) -> list[dict]:
    """Comme rows(), mais avec la requete brute : l'agregation JSON est ajoutee."""
    return rows(f"select coalesce(json_agg(row_to_json(x)), '[]') from ({sql}) x")


def table(items: list[dict], cols: list[str]) -> None:
    if not items:
        print("(vide)")
        return
    widths = {c: max(len(c), *(len(str(i.get(c, "") or "")[:44]) for i in items)) for c in cols}
    print("  ".join(c.ljust(widths[c]) for c in cols))
    for i in items:
        print("  ".join(str(i.get(c, "") or "")[:44].ljust(widths[c]) for c in cols))


# ------------------------------------------------------------------ commands

def cmd_submit(a) -> None:
    if a.status_check:
        pass
    target = a.target
    kind = a.kind or ("systemd_unit" if a.unit else "command")
    env = {}
    for kv in a.env or []:
        k, _, v = kv.partition("=")
        env[k] = v
    cols = {
        "key": q(a.key), "kind": q(kind), "target": q(target), "run_as": q(a.run_as),
        "workdir": q(a.workdir), "cpu_class": q(a.cpu_class), "mem_min_mb": str(a.mem),
        "llm_cost": q(a.llm), "est_minutes": str(a.est) if a.est else "null",
        "paid_cap_cents": str(a.paid_cap), "priority": str(a.priority),
        "while_busy": "true" if a.while_busy else "false",
        "needs_absence": "true" if getattr(a, "needs_absence", False) else "false",
        "requires_gpu": "true" if a.requires_gpu else "false",
        "not_before": f"now() + interval '{a.not_before} minutes'" if a.not_before else "now()",
        "deadline": f"now() + interval '{a.deadline} minutes'" if a.deadline else "null",
        "env": q(json.dumps(env)) + "::jsonb",
        "created_by": q(a.by or "cli"),
    }
    conflict = f"on conflict (key) do update set updated_at = now() returning id" if a.key else "returning id"
    tid = psql(
        f"insert into tasks ({', '.join(cols)}) values ({', '.join(cols.values())}) {conflict}"
    )
    psql(
        "insert into decisions (task_id, action, actor, reason) values "
        f"({tid}, 'submit', {q(a.by or 'cli')}, {q(f'{kind} {target} ({a.cpu_class}, llm {a.llm})')})",
        tuples=False,
    )
    print(f"tache #{tid} en file : {kind} {target}")


def cmd_list(a) -> None:
    where = f"where status = {q(a.status)}" if a.status else ""
    items = jrows(
        "select id, status, priority, cpu_class, llm_cost, key, left(target, 40) as target,"
        "       to_char(created_at, 'HH24:MI') as cree, to_char(started_at, 'HH24:MI') as demarre,"
        "       minutes_taken, attempts, exit_code "
        f"from queue {where} limit {a.limit}"
    )
    table(items, ["id", "status", "priority", "cpu_class", "llm_cost", "target", "cree", "demarre", "minutes_taken", "attempts"])


def cmd_show(a) -> None:
    t = jrows(f"select * from tasks where id = {int(a.id)}")
    if not t:
        print("tache inconnue")
        return
    print(json.dumps(t[0], indent=2, default=str))
    ds = jrows(
        "select to_char(at, 'HH24:MI:SS') as at, action, actor, left(reason, 70) as reason "
        f"from decisions where task_id = {int(a.id)} order by at desc limit 10"
    )
    print("\ndecisions :")
    table(ds, ["at", "action", "actor", "reason"])


def cmd_why(a) -> None:
    m = jrows("select value from state where key='last_metrics'")
    if not m:
        print("pas encore de metriques (dispatcher arrete ?)")
        return
    m = m[0]["value"]
    b = m.get("budget", {})
    print(
        f"load {m['load1']} / {m['threads']} threads | RAM libre {m['mem_avail_mb']} Mo | "
        f"marc cpu {m['marc_cpu_pct']}% busy={m['marc_busy']} present={m['marc_present']} "
        f"connecte={m.get('marc_connected', '?')} | "
        f"gpu: {m['gpu'] or 'aucun'} | modele local: {m['local_model_running']} | "
        f"budget payant restant {b.get('left_cents')} c | pause={m.get('paused')}"
    )
    if m.get("marc_connected") and m.get("marc_connected_why"):
        print(f"connecte: {m['marc_connected_why']}")
    if m.get("presence"):
        until = (m.get("presence_until") or "")[11:16]
        print(f"presence: {m['presence']} ({m.get('presence_why')})"
              + (f" jusqu'a {until}" if until else ""))
    if getattr(a, "id", None):
        t = jrows(
            "select id, status, cpu_class, mem_min_mb, llm_cost, priority, while_busy,"
            " needs_absence,"
            f" to_char(not_before, 'HH24:MI') as not_before, note from tasks where id={int(a.id)}"
        )
        if t:
            print(json.dumps(t[0], indent=2, default=str))
            d = jrows(
                "select left(reason, 90) as reason from decisions "
                f"where task_id={int(a.id)} and action in ('defer','start','finish','fail') order by at desc limit 3"
            )
            for x in d:
                print(" ", x["reason"])


def cmd_metrics(a) -> None:
    cmd_why(a)


def cmd_set(a, key: str, value: str) -> None:
    psql("insert into state (key, value) values "
         f"({q(key)}, {q(value)}::jsonb) on conflict (key) do update set value = excluded.value, updated_at = now()",
         tuples=False)
    psql("insert into decisions (action, actor, reason) values "
         f"({q('pause' if value == 'true' else 'resume')}, 'cli', {q(key + ' = ' + value)})", tuples=False)
    print(f"{key} = {value}")


def cmd_cancel(a) -> None:
    psql(f"update tasks set status='cancelled', finished_at=now(), updated_at=now(), "
         f"note={q(a.reason or 'annule par le cli')} where id={int(a.id)} and status in ('queued','blocked')",
         tuples=False)
    psql("insert into decisions (task_id, action, actor, reason) values "
         f"({int(a.id)}, 'skip', 'cli', {q(a.reason or 'annule par le cli')})", tuples=False)
    print(f"tache {a.id} annulee")


def cmd_retry(a) -> None:
    psql(f"update tasks set status='queued', not_before=now(), attempts=0, updated_at=now() where id={int(a.id)}",
         tuples=False)
    print(f"tache {a.id} remise en file")


def cmd_digest(a) -> None:
    m = jrows("select value from state where key='last_metrics'")
    b = {}
    if m:
        v = m[0]["value"]
        b = v.get("budget", {})
        pres = v.get("presence") or "?"
        until = (v.get("presence_until") or "")[11:16]
        print(
            f"machine: load {v['load1']}/{v['threads']}, RAM libre {v['mem_avail_mb']} Mo, "
            f"marc busy={v['marc_busy']}, presence={pres}"
            + (f" jusqu'a {until}" if until else "") + ", "
            f"gpu={'oui' if v['gpu'] else 'non'}, "
            f"budget payant restant {b.get('left_cents')} c"
        )
    pend = jrows("select id, action, left(reason, 60) as reason, to_char(at, 'HH24:MI') as at "
                 "from decisions where not notified order by at limit 30")
    print("\ndecisions non notifiees :")
    table(pend, ["at", "id", "action", "reason"])
    q_ = jrows("select id, status, priority, left(target, 30) as target, left(coalesce(note,''), 40) as note from queue "
               "where status in ('queued','running','failed','blocked') limit 20")
    print("\nfile :")
    table(q_, ["id", "status", "priority", "target", "note"])
    if a.ack:
        n = psql("update decisions set notified = true where not notified returning id")
        print(f"\n{n.count(chr(10)) + 1 if n else 0} decisions marquees notifiees")


def cmd_state(a) -> None:
    """Etat deterministe (pas d'horodatage): sert de detecteur de changement
    pour le cerveau cron -- il ne se reveille que si quelque chose a bouge."""
    m = jrows("select value from state where key='last_metrics'")
    v = m[0]["value"] if m else {}
    counts = jrows("select status, count(*) as n from tasks group by status")
    by = {c["status"]: c["n"] for c in counts}
    last = jrows("select coalesce(max(id),0) as id, count(*) filter (where not notified) as pending from decisions")
    paused = psql("select value from state where key='paused'") or "false"
    budget = (v.get("budget") or {}).get("left_cents", "?")
    print(f"paused={paused}")
    print(f"budget_paid_left_cents={budget}")
    print(f"marc_busy={str(v.get('marc_busy')).lower()}")
    print(f"gpu={'yes' if v.get('gpu') else 'no'}")
    print(f"local_model={str(v.get('local_model_running')).lower()}")
    for st in ("queued", "running", "failed", "blocked", "done"):
        print(f"{st}={by.get(st, 0)}")
    print(f"last_decision_id={last[0]['id'] if last else 0}")
    print(f"unnotified_decisions={last[0]['pending'] if last else 0}")


def _presence_overrides() -> dict:
    v = jrows("select value from state where key='presence_overrides'")
    value = v[0]["value"] if v else {}
    return value if isinstance(value, dict) else {}


def _save_overrides(overrides: dict) -> None:
    psql("insert into state (key, value) values ('presence_overrides', "
         f"{q(json.dumps(overrides))}::jsonb) "
         "on conflict (key) do update set value = excluded.value, updated_at = now()",
         tuples=False)


def cmd_presence(a) -> None:
    """Presence de marc : fenetres sommeil/travail et overrides par date.

    taskq presence                    -> config, etat courant, prochaines bornes
    taskq presence off demain [note]  -> jour libre (pas de fenetre travail)
    taskq presence wfh 2026-11-04     -> teletravail (idem, autre etiquette)
    taskq presence clear demain       -> supprime l'override du jour
    """
    action = getattr(a, "action", None) or "show"
    cfg = presence.load_config()
    now = presence.now_local(cfg)
    overrides = _presence_overrides()
    if action in ("off", "wfh", "clear"):
        if not getattr(a, "when", None):
            print(f"usage: taskq presence {action} today|demain|YYYY-MM-DD [note]")
            return
        try:
            day = presence.resolve_day(cfg, a.when, now)
        except ValueError:
            print(f"date invalide: {a.when!r} (today | demain | YYYY-MM-DD)")
            return
        key = day.isoformat()
        if action == "clear":
            if overrides.pop(key, None) is None:
                print(f"{key}: aucun override")
                return
            _save_overrides(overrides)
            print(f"{key}: override supprime")
            return
        overrides[key] = {"kind": action, "note": getattr(a, "note", None) or "",
                          "by": "cli", "at": now.isoformat(timespec="seconds")}
        _save_overrides(overrides)
        print(f"{key} ({presence.DAY_NAMES[day.weekday()]}): {action} enregistre"
              + (f" ({a.note})" if getattr(a, "note", None) else ""))
        return
    # show : config + etat courant vu par le dispatcher + prochaines bornes
    sleep, work = cfg["sleep"], cfg["work"]
    days = ",".join(presence.DAY_NAMES[int(d) - 1] for d in work.get("days", []))
    print(f"fuseau {cfg.get('tz')} | sommeil {sleep['start']}-{sleep['end']} tous les jours "
          f"| travail {work['start']}-{work['end']} {days}")
    m = jrows("select value, round(extract(epoch from (now() - updated_at))) as age "
              "from state where key='last_metrics'")
    if m and m[0]["value"].get("presence"):
        v = m[0]["value"]
        until = (v.get("presence_until") or "")[11:16]
        print(f"maintenant: {v['presence']} ({v.get('presence_why')})"
              + (f" jusqu'a {until}" if until else "") + f" [lu il y a {int(m[0]['age'] or 0)} s]")
    else:
        print("maintenant: inconnu (dispatcher pas encore a jour)")
    print("prochaines bornes:")
    for at, label in presence.transitions(cfg, overrides, now):
        print(f"  {presence.DAY_NAMES[at.weekday()]} {at:%d/%m %H:%M} {label}")
    ahead = sorted(k for k in overrides if k >= now.date().isoformat())[:7]
    if ahead:
        print("overrides a venir:")
        for k in ahead:
            o = overrides.get(k) or {}
            print(f"  {k} {o.get('kind')}" + (f" ({o.get('note')})" if o.get("note") else ""))


def cmd_unblock(a) -> None:
    psql("update tasks set status='queued', note='debloque', updated_at=now() where status='blocked'", tuples=False)
    print("taches bloquees remises en file")


def main() -> int:
    ap = argparse.ArgumentParser(prog="taskq", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("submit", aliases=["run"], help="poser une tache (commande shell ou unite systemd)")
    s.add_argument("target")
    s.add_argument("--kind", choices=["command", "systemd_unit"])
    s.add_argument("--unit", action="store_true", help="raccourci: kind=systemd_unit")
    s.add_argument("--key", help="cle d'idempotence")
    s.add_argument("--class", dest="cpu_class", default="medium", choices=["light", "medium", "heavy"])
    s.add_argument("--mem", type=int, default=512, help="Mo de RAM libre exiges")
    s.add_argument("--llm", default="none", choices=["none", "free", "paid"])
    s.add_argument("--paid-cap", type=int, default=0, help="centimes payants max consommes")
    s.add_argument("--est", type=int, help="duree estimee en minutes")
    s.add_argument("--priority", type=int, default=100, help="plus petit = plus urgent")
    s.add_argument("--not-before", type=int, help="demarrer au plus tot dans N minutes")
    s.add_argument("--deadline", type=int, help="doit demarrer dans N minutes")
    s.add_argument("--while-busy", action="store_true", help="peut tourner pendant que marc travaille")
    s.add_argument("--absence", dest="needs_absence", action="store_true",
                   help="ne tourne QUE pendant une absence de marc (fenetres sommeil/travail, "
                        "ou 15 min sans interaction hermes/ssh/webui); interrompue a son retour")
    s.add_argument("--requires-gpu", action="store_true")
    s.add_argument("--run-as", default="hermes")
    s.add_argument("--workdir")
    s.add_argument("--env", action="append", metavar="K=V")
    s.add_argument("--by", help="auteur")
    s.set_defaults(func=cmd_submit)

    s2 = sub.add_parser("unit", help="raccourci pour une unite systemd")
    s2.add_argument("unit")
    s2.set_defaults(func=lambda a: cmd_submit(argparse.Namespace(
        target=a.unit, kind=None, unit=True, key=a.key, cpu_class=a.cpu_class, mem=a.mem, llm=a.llm,
        paid_cap=a.paid_cap, est=a.est, priority=a.priority, not_before=a.not_before, deadline=a.deadline,
        while_busy=a.while_busy, needs_absence=a.needs_absence, requires_gpu=a.requires_gpu, run_as="hermes",
        workdir=None, env=None, by=a.by, status_check=False)))

    s = sub.add_parser("list"); s.add_argument("--status"); s.add_argument("--limit", type=int, default=25)
    s.set_defaults(func=cmd_list)

    s = sub.add_parser("show"); s.add_argument("id"); s.set_defaults(func=cmd_show)
    s = sub.add_parser("why"); s.add_argument("id", nargs="?"); s.set_defaults(func=cmd_why)
    s = sub.add_parser("metrics"); s.set_defaults(func=cmd_metrics)
    s = sub.add_parser("pause"); s.set_defaults(func=lambda a: cmd_set(a, "paused", "true"))
    s = sub.add_parser("resume"); s.set_defaults(func=lambda a: cmd_set(a, "paused", "false"))
    s = sub.add_parser("cancel"); s.add_argument("id"); s.add_argument("--reason"); s.set_defaults(func=cmd_cancel)
    s = sub.add_parser("retry"); s.add_argument("id"); s.set_defaults(func=cmd_retry)
    s = sub.add_parser("unblock"); s.set_defaults(func=cmd_unblock)
    s = sub.add_parser("state"); s.set_defaults(func=cmd_state)
    s = sub.add_parser("presence",
                       help="presence de marc: fenetres sommeil/travail, overrides off/wfh")
    s.add_argument("action", nargs="?", default="show", choices=["show", "off", "wfh", "clear"])
    s.add_argument("when", nargs="?", help="today | demain | YYYY-MM-DD")
    s.add_argument("note", nargs="?", help="note libre pour off/wfh")
    s.set_defaults(func=cmd_presence)
    s = sub.add_parser("digest"); s.add_argument("--ack", action="store_true"); s.set_defaults(func=cmd_digest)

    for p in (s2,):
        p.add_argument("--key"); p.add_argument("--class", dest="cpu_class", default="medium", choices=["light", "medium", "heavy"])
        p.add_argument("--mem", type=int, default=512); p.add_argument("--llm", default="none", choices=["none", "free", "paid"])
        p.add_argument("--paid-cap", type=int, default=0); p.add_argument("--est", type=int)
        p.add_argument("--priority", type=int, default=100); p.add_argument("--not-before", type=int)
        p.add_argument("--deadline", type=int); p.add_argument("--while-busy", action="store_true")
        p.add_argument("--absence", dest="needs_absence", action="store_true")
        p.add_argument("--requires-gpu", action="store_true"); p.add_argument("--by")

    a = ap.parse_args()
    a.__dict__.setdefault("status_check", False)
    a.func(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
