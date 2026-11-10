#!/usr/bin/env python3
"""taskq-api : API JSON + webui de la file de taches de tower.

Zero dependance (stdlib + psql, comme le dispatcher). Ecoute en loopback
uniquement : l'acces distant passe par Pangolin (SSO) -> newt -> 127.0.0.1.

  GET  /              -> la webui (page unique, poll 5 s de /api/state)
  GET  /api/state     -> instantane JSON (file, decisions, hotes, metriques)
  GET  /api/healthz   -> {"status":"ok"} (healthcheck Pangolin)
  GET  /api/logs?id=N -> journal systemd de la tache (unite taskq-N ou unite cible)
  GET  /manifest.webmanifest /sw.js /icon.svg -> PWA (installable sur Android)
  POST /api/action    -> {"action": pause|resume|ack|unblock|cancel|retry, "id": n}

Les actions sont celles du CLI `taskq` (meme SQL, actor "webui" dans
`decisions`). Le protocole de flotte (/worker/*, tokens) arrivera ici, sous la
meme unite, avec authentification par hote.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB = os.environ.get("TASKQ_DATABASE_URL", "postgresql://taskq@127.0.0.1/taskq")
PORT = int(os.environ.get("TASKQ_API_PORT", "9077"))
BIND = os.environ.get("TASKQ_API_BIND", "127.0.0.1")
ACTOR = "webui"


def psql(sql: str, tuples: bool = True) -> str:
    args = ["psql", DB, "-v", "ON_ERROR_STOP=1", "-q"] + (["-tA"] if tuples else []) + ["-c", sql]
    out = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(f"psql: {out.stderr.strip()[:300]}")
    return out.stdout.strip()


def one(sql: str):
    txt = psql(sql)
    return json.loads(txt) if txt else None


def rows(sql: str) -> list:
    return one(f"select coalesce(json_agg(row_to_json(x)), '[]') from ({sql}) x") or []


def exec_(sql: str) -> None:
    psql(sql, tuples=False)


def q(v) -> str:
    if v is None:
        return "null"
    return "'" + str(v).replace("'", "''") + "'"


def query(path: str, name: str, default: str = "") -> str:
    vals = parse_qs(urlsplit(path).query).get(name) or [default]
    return vals[0]


JOURNALCTL = os.environ.get("TASKQ_JOURNALCTL", "journalctl")
UNIT_RE = re.compile(r"^[A-Za-z0-9@_.:-]+$")


def logs(tid: int, lines: int = 200) -> dict:
    """Journal systemd d'une tache : unite transitoire taskq-<id> pour une
    commande, unite cible pour un job `systemd_unit`."""
    t = one(f"select row_to_json(x) from (select unit, target, kind from tasks where id={int(tid)}) x")
    if not t:
        return {"ok": False, "error": f"tache {tid} inconnue"}
    unit = t.get("unit") or (t.get("target") if t.get("kind") == "systemd_unit" else f"taskq-{int(tid)}")
    if not UNIT_RE.match(str(unit or "")):
        return {"ok": False, "error": "unite invalide"}
    n = max(20, min(int(lines or 200), 1000))
    try:
        out = subprocess.run(
            [JOURNALCTL, "-u", str(unit), "-n", str(n), "--no-pager", "-o", "short-iso"],
            capture_output=True, text=True, timeout=25,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "unit": unit, "error": "journalctl: delai depasse"}
    return {"ok": out.returncode == 0, "unit": unit,
            "log": out.stdout[-24000:], "err": out.stderr.strip()[:300]}


def log(msg: str) -> None:
    print(f"{dt.datetime.now().strftime('%H:%M:%S')} {msg}", flush=True)


def state() -> dict:
    m = one("select value from state where key='last_metrics'") or {}
    paused = one("select value from state where key='paused'") or "false"
    counts = {r["status"]: r["n"] for r in rows("select status, count(*) as n from tasks group by status")}
    unacked = int(psql("select count(*) from decisions where not notified") or "0")
    hosts = rows(
        "select name, caps, metrics, enabled, quarantined_until::text as quarantined_until,"
        " left(coalesce(note, ''), 120) as note, heartbeat::text as heartbeat,"
        " coalesce(round(extract(epoch from (now() - heartbeat)))::int, -1) as silent_s"
        " from hosts order by name"
    )
    queue = rows(
        "select id, status, priority, key, kind, left(target, 72) as target, cpu_class,"
        " mem_min_mb, llm_cost, est_minutes, while_busy, needs_absence,"
        " to_char(not_before, 'HH24:MI') as not_before, to_char(deadline, 'HH24:MI') as deadline,"
        " to_char(started_at, 'HH24:MI') as started, minutes_taken, attempts, exit_code,"
        " note, assigned_host, to_char(lease_expires_at, 'HH24:MI') as lease"
        " from queue where status not in ('done', 'cancelled')"
        " order by case status when 'running' then 0 when 'queued' then 1 when 'blocked' then 2 else 3 end,"
        " priority, created_at limit 80"
    )
    decisions = rows(
        "select id, to_char(at, 'HH24:MI:SS') as at, action, actor, task_id,"
        " left(coalesce(reason, ''), 160) as reason from decisions order by at desc limit 25"
    )
    return {
        "now": dt.datetime.now().isoformat(timespec="seconds"),
        "paused": paused in ("true", True),
        "metrics": m,
        "budget": m.get("budget") or {},
        "counts": counts,
        "unacked": unacked,
        "hosts": hosts,
        "queue": queue,
        "decisions": decisions,
    }


def action(body: dict) -> dict:
    a = (body.get("action") or "").strip()
    tid = body.get("id")
    reason = (body.get("reason") or "").strip() or None
    if a == "pause":
        exec_("insert into state (key, value) values ('paused', 'true'::jsonb)"
              " on conflict (key) do update set value = 'true'::jsonb, updated_at = now()")
        exec_(f"insert into decisions (action, actor, reason) values ('pause', {q(ACTOR)}, 'file en pause (webui)')")
    elif a == "resume":
        exec_("insert into state (key, value) values ('paused', 'false'::jsonb)"
              " on conflict (key) do update set value = 'false'::jsonb, updated_at = now()")
        exec_(f"insert into decisions (action, actor, reason) values ('resume', {q(ACTOR)}, 'file relancee (webui)')")
    elif a == "ack":
        n = psql("update decisions set notified = true where not notified returning id")
        return {"ok": True, "action": a, "acked": n.count("\n") + 1 if n else 0}
    elif a == "unblock":
        exec_("update tasks set status='queued', note='debloque', updated_at=now() where status='blocked'")
        exec_(f"insert into decisions (action, actor, reason) values ('unblock', {q(ACTOR)}, 'taches bloquees remises en file (webui)')")
    elif a == "cancel":
        if tid is None:
            return {"ok": False, "error": "id requis"}
        exec_(f"update tasks set status='cancelled', finished_at=now(), updated_at=now(),"
              f" note={q(reason or 'annule par la webui')} where id={int(tid)} and status in ('queued', 'blocked')")
        exec_(f"insert into decisions (task_id, action, actor, reason) values ({int(tid)}, 'skip', {q(ACTOR)}, {q(reason or 'annule par la webui')})")
    elif a == "retry":
        if tid is None:
            return {"ok": False, "error": "id requis"}
        exec_(f"update tasks set status='queued', not_before=now(), attempts=0, updated_at=now() where id={int(tid)}")
        exec_(f"insert into decisions (task_id, action, actor, reason) values ({int(tid)}, 'note', {q(ACTOR)}, 'remise en file (webui)')")
    else:
        return {"ok": False, "error": f"action inconnue: {a or '(vide)'}"}
    log(f"action {a} {('#' + str(tid)) if tid is not None else ''}")
    return {"ok": True, "action": a}


# ------------------------------------------------------------------- flotte
# Protocole de flotte : les workers distant (deck, laptop, anywhere, mac)
# appellent ces routes en PULL. Aucun port ouvert chez eux, aucune donnee
# d'etat locale : le master garde la politique (pause, budget, GPU) et le bail
# de chaque tache. Un hote qui se tait (veille, wifi, reboot) voit son bail
# expirer et sa tache remise en file par le reaper (thread ci-dessous).

WORKER_BIND = os.environ.get("TASKQ_WORKER_BIND", "127.0.0.1")
WORKER_PORT = int(os.environ.get("TASKQ_WORKER_PORT", "9078"))
TOKENS_FILE = os.environ.get("TASKQ_WORKER_TOKENS", "/etc/taskq/worker-tokens.json")
LEASE_S = int(os.environ.get("TASKQ_WORKER_LEASE", "120"))
MAX_LEASE_LOSSES = 5


def tokens() -> dict:
    """{nom d'hote -> jeton}. Fichier rendu par Nix depuis sops (0600)."""
    try:
        with open(TOKENS_FILE) as f:
            return {str(k): str(v) for k, v in json.load(f).items() if v}
    except Exception:
        return {}


def host_of(auth: str | None) -> str | None:
    if not auth or not auth.startswith("Bearer "):
        return None
    tok = auth[7:].strip()
    for name, known in tokens().items():
        if tok and tok == known:
            return name
    return None


def caps_sql(caps) -> str:
    vals = [c for c in (caps or []) if isinstance(c, str) and c]
    if not vals:
        return "'{}'::text[]"
    return "array[" + ",".join(q(c) for c in vals) + "]::text[]"


def jq(v) -> str:
    return q(json.dumps(v, default=str)) + "::jsonb"


def reaper() -> None:
    """Remet en file les taches dont le worker s'est tu (bail expire)."""
    try:
        lost = rows(
            "with lost as ("
            " update tasks set status='queued', assigned_host=null,"
            "  lease_expires_at=null, lease_losses=lease_losses+1,"
            "  not_before=now() + interval '1 minute', updated_at=now(),"
            "  note='worker silencieux: bail expire, remise en file'"
            " where status='running' and assigned_host is not null"
            "  and lease_expires_at < now()"
            " returning id, assigned_host, lease_losses)"
            " select id, assigned_host, lease_losses from lost"
        )
    except Exception as e:
        log(f"reaper: {e!r}")
        return
    for t in lost or []:
        log(f"bail expire: #{t['id']} perdu par {t['assigned_host']}")
        exec_(
            "insert into decisions (task_id, action, actor, reason)"
            f" values ({int(t['id'])}, 'defer', 'reaper', "
            f"{q('hote ' + str(t['assigned_host']) + ' muet: bail expire, tache remise en file')})"
        )
        if int(t["lease_losses"] or 0) >= MAX_LEASE_LOSSES:
            exec_(
                "update tasks set status='failed', finished_at=now(), updated_at=now(),"
                f" note={q('abandonnee: ' + str(t['lease_losses']) + ' baux perdus')}"
                f" where id={int(t['id'])}"
            )
            exec_(
                "insert into decisions (task_id, action, actor, reason)"
                f" values ({int(t['id'])}, 'fail', 'reaper', "
                f"{q('abandonnee apres ' + str(t['lease_losses']) + ' baux perdus')})"
            )


def reaper_loop() -> None:
    while True:
        time.sleep(20)
        reaper()


def worker_beat(name: str, body: dict) -> dict:
    caps = body.get("caps") or []
    metrics = body.get("metrics") or {}
    running = [int(x) for x in (body.get("running") or [])]
    caps_json = {c: True for c in caps if isinstance(c, str) and c}
    exec_(
        "insert into hosts (name, caps, metrics, heartbeat) values"
        f" ({q(name)}, {jq(caps_json)}, {jq(metrics)}, now())"
        " on conflict (name) do update set caps=excluded.caps,"
        " metrics=excluded.metrics, heartbeat=now(), enabled=true"
    )
    run_arr = "array[" + ",".join(str(i) for i in running) + "]::int[]" if running else "'{}'::int[]"
    # Le bail se renouvelle a chaque battement : une tache longue vit tant que
    # l'hote bat, et meurt des qu'il se tait.
    exec_(
        "update tasks set lease_expires_at = now()"
        f" + interval '{int(LEASE_S)} seconds', updated_at=now()"
        f" where assigned_host={q(name)} and status='running' and id = any({run_arr})"
    )
    abort = rows(
        "select id from tasks where status='running'"
        f" and assigned_host={q(name)}"
        f" and not (id = any({run_arr}))"
    )
    claim: list = []
    paused = one("select value from state where key='paused'") in ("true", True)
    free = int(body.get("free_slots") or 0)
    if body.get("accept") and free > 0 and not paused:
        claim = rows(
            f"with pick as (select t.id from tasks t"
            f" where t.status='queued' and t.not_before <= now()"
            f"  and t.requires <> '{{}}'::text[]"
            f"  and t.requires <@ {caps_sql(caps)}"
            f"  and (not t.gpu or 'gpu' = any({caps_sql(caps)}))"
            f"  and (t.llm_cost <> 'paid' or coalesce((select (s.value #>> '{{}}')::int"
            f"        from state s where s.key='paid_budget_cents_per_day'), 0)"
            f"     > coalesce((select (s.value->>'cents')::int from state s"
            f"        where s.key='paid_spent_today' and s.value->>'day' ="
            f"        to_char(now() at time zone 'utc', 'YYYY-MM-DD')), 0))"
            f"  order by t.priority, t.created_at limit {free}"
            f"  for update skip locked),"
            f" upd as (update tasks t set status='running', assigned_host={q(name)},"
            f"  started_at=coalesce(t.started_at, now()), updated_at=now(),"
            f"  attempts=t.attempts+1, unit=null,"
            f"  lease_expires_at=now() + interval '{int(LEASE_S)} seconds'"
            f" from pick where t.id=pick.id"
            f" returning t.id, t.kind, t.target, t.run_as, t.workdir, t.env,"
            f"  t.cpu_class, t.mem_min_mb, t.gpu, t.llm_cost, t.est_minutes,"
            f"  t.priority, t.key, t.attempts, t.max_attempts)"
            f" select id, kind, target, run_as, workdir, env, cpu_class,"
            f"  mem_min_mb, gpu, llm_cost, est_minutes, priority, key,"
            f"  attempts, max_attempts from upd"
        )
        for t in claim:
            why = "remis a %s (%s load, %s Mo libres)" % (
                name, metrics.get("load1", "?"), metrics.get("mem_avail_mb", "?"))
            exec_(
                "insert into decisions (task_id, action, actor, reason)"
                f" values ({int(t['id'])}, 'start', {q('worker:' + name)}, {q(why)})"
            )
            log(f"#{t['id']} -> {name}")
    return {"ok": True, "host": name, "claim": claim, "abort": [r["id"] for r in abort],
            "lease_s": LEASE_S, "paused": paused}


def worker_report(name: str, body: dict) -> dict:
    tid = int(body.get("id") or 0)
    status = body.get("status") if body.get("status") in ("done", "failed") else "failed"
    code = body.get("exit_code")
    note = (body.get("note") or "")[:500]
    n = psql(
        f"update tasks set status={q(status)}, exit_code={code if code is not None else 'null'},"
        f" note={q(note)}, finished_at=now(), updated_at=now(), lease_expires_at=null"
        f" where id={tid} and assigned_host={q(name)} and status='running'"
        " returning id"
    )
    if not n:
        log(f"report #{tid} de {name} ignore (tache plus assignee)")
        return {"ok": True, "ignored": True}
    exec_(
        "insert into decisions (task_id, action, actor, reason)"
        f" values ({tid}, {q('finish' if status == 'done' else 'fail')}, "
        f"{q('worker:' + name)}, {q(note[:200])})"
    )
    log(f"#{tid} {status} sur {name}")
    return {"ok": True, "id": tid, "status": status}


PAGE = r"""<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>taskq</title>
<meta name="theme-color" content="#1e1e2e">
<meta name="description" content="File de taches lourdes de tower">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="taskq">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/icon.svg">
<style>
:root{
  color-scheme:dark;
  --base:#1e1e2e;--mantle:#181825;--crust:#11111b;
  --s0:#313244;--s1:#45475a;--s2:#585b70;--ov0:#6c7086;--ov1:#7f849c;
  --sub0:#a6adc8;--sub1:#bac2de;--text:#cdd6f4;
  --lav:#b4befe;--blue:#89b4fa;--sap:#74c7ec;--teal:#94e2d5;--green:#a6e3a1;
  --yellow:#f9e2af;--peach:#fab387;--maroon:#eba0ac;--red:#f38ba8;--mauve:#cba6f7;
  --r:14px;
}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{
  margin:0;background:var(--base);color:var(--text);
  font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
  -webkit-tap-highlight-color:transparent;overscroll-behavior-y:contain;
}
h1,h2,h3{margin:0;font-weight:650}
button{font:inherit;color:inherit;cursor:pointer}
button:focus-visible,input:focus-visible,summary:focus-visible{outline:2px solid var(--lav);outline-offset:2px}

header{
  position:sticky;top:0;z-index:9;
  padding:calc(10px + env(safe-area-inset-top)) 14px 10px;
  background:rgba(24,24,37,.88);backdrop-filter:blur(12px);
  border-bottom:1px solid var(--s0);
  display:flex;align-items:center;gap:10px;
}
.brand{display:flex;align-items:center;gap:10px;min-width:0;flex:1}
.mark{width:34px;height:34px;flex:none}
.mark rect{fill:#24243a}
.mark path{stroke:var(--lav);stroke-width:2;fill:none;stroke-linecap:round;stroke-linejoin:round}
.brand h1{font-size:19px;letter-spacing:.2px;line-height:1.1}
.brand h1 span{color:var(--lav)}
.stamp{display:flex;align-items:center;gap:6px;color:var(--sub0);font-size:11.5px;
       margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.dot{width:7px;height:7px;border-radius:50%;background:var(--green);flex:none;
     box-shadow:0 0 0 0 rgba(166,227,161,.5);animation:pulse 2.4s infinite}
.dot.off{background:var(--red);animation:none}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(166,227,161,.45)}70%{box-shadow:0 0 0 7px rgba(166,227,161,0)}100%{box-shadow:0 0 0 0 rgba(166,227,161,0)}}
@media (prefers-reduced-motion:reduce){.dot{animation:none}}
.topacts{display:flex;gap:6px;flex:none}
.btn{
  border:1px solid var(--s1);background:var(--s0);border-radius:10px;
  padding:8px 12px;font-size:13px;font-weight:550;white-space:nowrap;
  transition:border-color .15s,color .15s,background .15s;
}
.btn:hover{border-color:var(--lav);color:var(--lav)}
.btn.ghost{background:transparent;border-color:var(--s0);color:var(--sub1)}
.btn.warn{background:rgba(249,226,175,.12);border-color:rgba(249,226,175,.35);color:var(--yellow)}
.btn.go{background:rgba(166,227,161,.12);border-color:rgba(166,227,161,.35);color:var(--green)}
.btn.danger:hover{border-color:var(--red);color:var(--red)}
.btn b{font-weight:700}

main{max-width:1080px;margin:0 auto;padding:14px 14px calc(56px + env(safe-area-inset-bottom))}

.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(146px,1fr));gap:8px}
.tile{background:var(--mantle);border:1px solid var(--s0);border-radius:var(--r);padding:10px 12px 11px;min-width:0}
.tile .k{font-size:10px;letter-spacing:.9px;text-transform:uppercase;color:var(--ov1);font-weight:650}
.tile .v{font-size:18px;font-weight:650;letter-spacing:-.3px;margin-top:3px;
         font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tile .s{font-size:11.5px;color:var(--sub0);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tile .bar{height:4px;border-radius:99px;background:var(--s0);margin-top:8px;overflow:hidden}
.tile .bar i{display:block;height:100%;border-radius:99px;background:var(--lav);transition:width .4s ease}
.tile.ok .v{color:var(--green)} .tile.warn .v{color:var(--yellow)} .tile.bad .v{color:var(--red)}
.tile.info .v{color:var(--sap)} .tile.mute .v{color:var(--sub1)}

.fleet{color:var(--sub0);font-size:12px;margin:10px 2px 0}
.fleet .h{display:inline-flex;align-items:center;gap:6px;background:var(--mantle);
          border:1px solid var(--s0);border-radius:99px;padding:3px 10px;margin:4px 6px 0 0}
.fleet .h b{color:var(--text);font-weight:600}

.bar2{position:sticky;top:calc(54px + env(safe-area-inset-top));z-index:8;margin:14px -14px 0;
      padding:8px 14px;background:linear-gradient(var(--base) 72%,rgba(30,30,46,0))}
.chips{display:flex;gap:6px;overflow-x:auto;scrollbar-width:none;padding-bottom:2px}
.chips::-webkit-scrollbar{display:none}
.chip{border:1px solid var(--s0);background:var(--mantle);border-radius:99px;
      padding:6px 12px;font-size:12.5px;font-weight:550;color:var(--sub0);white-space:nowrap;
      display:inline-flex;gap:6px;align-items:center}
.chip b{font-size:11px;color:var(--ov1);font-variant-numeric:tabular-nums}
.chip[aria-selected=true]{background:rgba(180,190,254,.14);border-color:rgba(180,190,254,.45);color:var(--lav)}
.chip[aria-selected=true] b{color:var(--lav)}
.chip:hover{border-color:var(--s2)}
.search{
  width:100%;margin-top:8px;background:var(--mantle);border:1px solid var(--s0);
  border-radius:10px;color:var(--text);padding:9px 12px;font-size:13.5px;min-height:40px;
}
.search::placeholder{color:var(--ov0)}

.list{list-style:none;margin:10px 0 0;padding:0}
.task{background:var(--mantle);border:1px solid var(--s0);border-left:3px solid var(--s1);
      border-radius:var(--r);margin-bottom:8px;overflow:hidden;transition:border-color .15s}
.task.running{border-left-color:var(--green)}
.task.queued{border-left-color:var(--lav)}
.task.blocked{border-left-color:var(--yellow)}
.task.failed{border-left-color:var(--red)}
.task:hover{border-color:var(--s1)}
.row{display:grid;grid-template-columns:1fr auto;grid-template-areas:"head chev" "target target" "meta chev2";
     gap:5px 10px;width:100%;padding:11px 12px;background:none;border:0;text-align:left}
.head{grid-area:head;display:flex;align-items:center;gap:8px;min-width:0;flex-wrap:wrap}
.tid{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;color:var(--ov1);font-weight:600}
.prio{font-size:10.5px;color:var(--ov1);border:1px solid var(--s0);border-radius:6px;padding:0 5px;
      font-variant-numeric:tabular-nums}
.badge{font-size:10.5px;font-weight:650;border-radius:6px;padding:2px 7px;letter-spacing:.2px;
       background:rgba(127,132,156,.16);color:var(--sub1)}
.badge.running{background:rgba(166,227,161,.16);color:var(--green)}
.badge.queued{background:rgba(180,190,254,.16);color:var(--lav)}
.badge.blocked{background:rgba(249,226,175,.16);color:var(--yellow)}
.badge.failed,.badge.expired{background:rgba(243,139,168,.16);color:var(--red)}
.badge.done{background:rgba(166,227,161,.13);color:var(--green)}
.target{grid-area:target;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px;
        color:var(--sub1);overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;
        overflow-wrap:anywhere}
.task.open .target{color:var(--text)}
.meta{grid-area:meta;display:flex;gap:10px;flex-wrap:wrap;font-size:11.5px;color:var(--ov1);
      font-variant-numeric:tabular-nums}
.meta .m{display:inline-flex;gap:4px;align-items:center}
.meta .m b{color:var(--sub1);font-weight:600}
.chev{grid-area:chev;align-self:center;color:var(--ov0);font-size:18px;line-height:1;
      transition:transform .18s;padding:4px}
.task.open .chev{transform:rotate(90deg);color:var(--lav)}
.detail{padding:0 12px 12px;border-top:1px dashed var(--s0);margin-top:2px}
.cmd{background:var(--crust);border:1px solid var(--s0);border-radius:10px;padding:9px 10px;margin:10px 0}
.cmd pre{margin:0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;
         color:var(--text);white-space:pre-wrap;overflow-wrap:anywhere;max-height:9em;overflow:auto}
.kv{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px 14px;margin:10px 0 0}
.kv div{min-width:0}
.kv dt{font-size:10px;letter-spacing:.8px;text-transform:uppercase;color:var(--ov1);font-weight:650}
.kv dd{margin:1px 0 0;font-size:12.5px;color:var(--sub1);overflow-wrap:anywhere}
.kv dd.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px;color:var(--sub0)}
.acts{display:flex;gap:7px;flex-wrap:wrap;margin-top:12px}
.acts .btn{flex:1 1 auto;min-height:38px}
.logs{margin:10px 0 0;background:var(--crust);border:1px solid var(--s0);border-radius:10px;
      padding:10px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px;
      line-height:1.5;color:var(--sub1);white-space:pre-wrap;overflow-wrap:anywhere;
      max-height:340px;overflow:auto}
.logs[hidden]{display:none}

.empty{color:var(--sub0);background:var(--mantle);border:1px dashed var(--s0);
       border-radius:var(--r);padding:16px;font-size:13px;text-align:center}

.decwrap{margin-top:22px}
.dechead{width:100%;display:flex;justify-content:space-between;align-items:center;
         background:var(--mantle);border:1px solid var(--s0);border-radius:var(--r);
         padding:11px 14px;font-size:13px;font-weight:600;color:var(--sub1)}
.dechead:hover{border-color:var(--s1)}
.dechead .chev{font-size:16px;transition:transform .18s}
.dechead[aria-expanded=true] .chev{transform:rotate(90deg);color:var(--lav)}
.dec{list-style:none;margin:8px 0 0;padding:0;background:var(--mantle);
     border:1px solid var(--s0);border-radius:var(--r);overflow:hidden}
.dec li{display:grid;grid-template-columns:52px 1fr;gap:2px 10px;padding:8px 13px;
        border-bottom:1px solid var(--crust);font-size:12.5px}
.dec li:last-child{border-bottom:none}
.dec .t{color:var(--ov1);font-family:ui-monospace,monospace;font-size:11.5px;font-variant-numeric:tabular-nums}
.dec .a{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.6px;color:var(--mauve)}
.dec .a.start,.dec .a.finish{color:var(--green)}
.dec .a.fail,.dec .a.expire{color:var(--red)}
.dec .a.defer,.dec .a.block{color:var(--yellow)}
.dec .a.pause{color:var(--peach)} .dec .a.resume{color:var(--sap)} .dec .a.skip{color:var(--ov1)}
.dec .r{color:var(--sub0);overflow-wrap:anywhere}
.dec .r .who{color:var(--ov0)}
footer{color:var(--ov0);font-size:11px;text-align:center;margin-top:26px}
.toast{position:fixed;left:50%;bottom:calc(18px + env(safe-area-inset-bottom));transform:translateX(-50%) translateY(140%);
       background:var(--s0);color:var(--text);border:1px solid var(--s1);border-radius:99px;
       padding:9px 16px;font-size:12.5px;z-index:20;transition:transform .22s;max-width:92vw;
       white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.toast.show{transform:translateX(-50%) translateY(0)}
@media (min-width:720px){
  .tiles{grid-template-columns:repeat(auto-fit,minmax(160px,1fr))}
  .row{grid-template-columns:1fr auto;grid-template-areas:"head chev" "target chev2" "meta chev3"}
  .brand h1{font-size:21px}
  main{padding-top:18px}
}
</style>
</head>
<body>
<header>
  <div class="brand">
    <svg class="mark" viewBox="0 0 32 32" aria-hidden="true">
      <rect x="1" y="1" width="30" height="30" rx="8"/>
      <path d="M9 11.5h14M9 16h9M9 20.5h11"/>
      <circle cx="24" cy="20.5" r="2.4" fill="none"/>
    </svg>
    <div style="min-width:0">
      <h1>task<span>q</span></h1>
      <div class="stamp"><span class="dot" id="dot"></span><span id="stamp">connexion…</span></div>
    </div>
  </div>
  <div class="topacts">
    <button class="btn ghost" id="install" hidden>Installer</button>
    <button class="btn ghost" id="ack" hidden>Lu</button>
    <button class="btn ghost" id="toggle">Pause</button>
  </div>
</header>

<main>
  <div class="tiles" id="tiles"></div>
  <p class="fleet" id="fleet"></p>

  <div class="bar2">
    <div class="chips" id="chips" role="tablist"></div>
    <input class="search" id="search" type="search" placeholder="filtrer par id, cible, note…" autocomplete="off" spellcheck="false">
  </div>

  <ul class="list" id="list"></ul>

  <section class="decwrap">
    <button class="dechead" id="decbtn" aria-expanded="false">
      <span id="declabel">Décisions récentes</span><span class="chev">›</span>
    </button>
    <ol class="dec" id="dec" hidden></ol>
  </section>

  <footer>taskq · tower · <span id="foot"></span></footer>
</main>

<div class="toast" id="toast"></div>

<script>
"use strict";
const $ = (s) => document.getElementById(s);
const esc = (v) => String(v === null || v === undefined ? "" : v)
  .replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const LBL = { queued: "en attente", running: "en cours", blocked: "bloquée",
              failed: "échec", done: "terminé", cancelled: "annulé", expired: "expiré" };
const PRES = { at_tower: ["à la machine", "warn"], away_work: ["absent (travail)", "ok"],
               away_sleep: ["absent (sommeil)", "ok"], nearby: ["près de tower", "info"] };

let DATA = null, HASH = "", filt = "all", txt = "", auto = true;
const open = new Set(), LOGS = new Map();
let busy = false, installEvt = null;

const euros = (c) => (c === null || c === undefined || isNaN(c)) ? "?" : (c / 100).toFixed(2).replace(".", ",") + " €";
const mem = (mb) => {
  if (mb === null || mb === undefined || isNaN(mb)) return "?";
  return mb >= 1024 ? (mb / 1024).toFixed(mb >= 10240 ? 0 : 1).replace(".", ",") + " Go" : Math.round(mb) + " Mo";
};
const num = (v, d) => (v === null || v === undefined || isNaN(v)) ? "?" : Number(v).toFixed(d === undefined ? 1 : d).replace(".", ",");
const dur = (m) => {
  if (m === null || m === undefined) return "";
  if (m < 1) return Math.round(m * 60) + " s";
  if (m < 60) return Math.round(m) + " min";
  return Math.floor(m / 60) + " h " + String(Math.round(m % 60)).padStart(2, "0");
};

function toast(msg) {
  const t = $("toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.remove("show"), 2600);
}

async function act(action, id, reason) {
  if (busy) return;
  busy = true;
  const body = { action };
  if (id !== undefined) body.id = id;
  if (reason) body.reason = reason;
  try {
    const r = await fetch("/api/action", { method: "POST",
      headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const j = await r.json().catch(() => ({}));
    toast(j.ok ? action + " ok" + (id ? " (#" + id + ")" : "") : "erreur: " + (j.error || r.status));
  } catch (e) {
    toast("erreur réseau");
  }
  busy = false;
  $("stamp").textContent = "actualisé " + new Date().toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  await tick();
}

function tile(k, v, s, cls, pct) {
  const bar = pct === undefined ? "" : '<div class="bar"><i style="width:' +
    Math.max(0, Math.min(100, pct)).toFixed(0) + '%;background:var(--' +
    (cls === "bad" ? "red" : cls === "warn" ? "yellow" : cls === "ok" ? "green" : "lav") + ')"></i></div>';
  return '<div class="tile ' + (cls || "") + '"><div class="k">' + k + '</div>' +
         '<div class="v">' + esc(v) + '</div><div class="s">' + esc(s || "") + '</div>' + bar + "</div>";
}

function tiles(s) {
  const m = s.metrics || {}, b = s.budget || {}, c = s.counts || {};
  const threads = m.threads || 1, load = m.load1;
  const queued = c.queued || 0, running = c.running || 0, failed = c.failed || 0, blocked = c.blocked || 0;
  const p = PRES[m.presence];
  const marc = p ? p[0] : (m.marc_connected ? "connecté" : (m.marc_busy ? "occupé" : "absent"));
  const mcls = p ? (p[1] === "warn" ? "warn" : p[1] === "ok" ? "ok" : "info") : (m.marc_busy ? "warn" : "ok");
  const used = b.spent_cents, cap = b.cap_cents;
  const out = [];
  out.push(tile("File", String(queued + running + blocked), running + " en cours · " + queued + " en attente",
    failed ? "bad" : queued ? "" : "ok"));
  out.push(tile("Load", num(load) + " / " + threads, "psi cpu " + num(m.psi_cpu, 0) + " · io " + num(m.psi_io, 2),
    load > 0.9 * threads ? "bad" : load > 0.6 * threads ? "warn" : "ok", (load / threads) * 100));
  out.push(tile("RAM libre", mem(m.mem_avail_mb), "swap " + mem(m.swap_used_mb) + " · " + mem(m.mem_total_mb) + " au total",
    (m.mem_avail_mb || 0) < 4096 ? "warn" : "ok"));
  out.push(tile("Marc", marc, m.presence_why || (m.marc_connected_why || ""), mcls));
  out.push(tile("Budget payant", euros(b.left_cents), "sur " + euros(cap) + " aujourd'hui",
    b.left_cents < 0 ? "bad" : b.left_cents < cap * 0.25 ? "warn" : "ok",
    cap ? (used / cap) * 100 : undefined));
  out.push(tile(m.gpu ? "GPU" : "Local", m.gpu || (m.local_model_running ? "modèle en cours" : "aucun GPU"),
    "échecs " + failed + " · terminées " + (c.done || 0), m.gpu ? "info" : "mute"));
  $("tiles").innerHTML = out.join("");
}

function fleet(s) {
  const hs = s.hosts || [];
  if (!hs.length) {
    $("fleet").textContent = "Flotte : aucun worker distant · tower exécute tout en local.";
    return;
  }
  $("fleet").innerHTML = "Flotte : " + hs.map((h) => {
    const silent = h.silent_s;
    const st = !h.enabled ? ["hors service", "bad"] : (h.quarantined_until ? ["quarantaine", "warn"]
      : (silent >= 0 && silent < 90 ? ["en ligne", "ok"] : ["silencieux " + silent + " s", "bad"]));
    return '<span class="h"><b>' + esc(h.name) + '</b> · ' + st[0] + "</span>";
  }).join("");
}

function chips(s) {
  const c = s.counts || {};
  const defs = [
    ["all", "Toutes", (s.queue || []).length],
    ["running", "En cours", c.running || 0],
    ["queued", "En attente", c.queued || 0],
    ["blocked", "Bloquées", c.blocked || 0],
    ["failed", "Échecs", (c.failed || 0) + (c.expired || 0)],
  ];
  $("chips").innerHTML = defs.map(([k, label, n]) =>
    '<button class="chip" role="tab" data-f="' + k + '" aria-selected="' + (filt === k) + '">' +
    label + " <b>" + n + "</b></button>").join("");
}

function matches(t) {
  if (filt === "failed") { if (t.status !== "failed" && t.status !== "expired") return false; }
  else if (filt !== "all" && t.status !== filt) return false;
  if (!txt) return true;
  const hay = [t.id, t.status, t.target, t.note, t.cpu_class, t.key, t.assigned_host]
    .join(" ").toLowerCase();
  return txt.toLowerCase().split(/\s+/).every((w) => hay.includes(w));
}

function when(t) {
  if (t.status === "running") {
    return "démarré " + (t.started || "?") + (t.minutes_taken !== null && t.minutes_taken !== undefined ? " · " + dur(t.minutes_taken) : "");
  }
  if (t.deadline) return "deadline " + t.deadline;
  if (t.not_before) return "prêt à " + t.not_before;
  return "";
}

function detail(t) {
  const kv = [];
  const add = (k, v, mono) => {
    if (v === null || v === undefined || v === "" ) return;
    kv.push('<div><dt>' + k + '</dt><dd' + (mono ? ' class="mono"' : "") + ">" + esc(v) + "</dd></div>");
  };
  add("type", t.kind === "command" ? "commande shell" : "unité systemd");
  add("classe", t.cpu_class + (t.mem_min_mb ? " · " + mem(t.mem_min_mb) + " min" : ""));
  add("hôte", t.assigned_host || "local", true);
  add("priorité", "P" + t.priority);
  add("essais", (t.attempts || 0) + " / 2");
  add("créée", t.created || "");
  add("estimé", t.est_minutes ? t.est_minutes + " min" : "");
  add("deadline", t.deadline || "");
  add("code sortie", t.exit_code === null || t.exit_code === undefined ? "" : t.exit_code);
  add("clé", t.key ? String(t.key).slice(0, 46) + (String(t.key).length > 46 ? "…" : "") : "", true);
  add("note", t.note || "");
  const acts = [];
  if (["failed", "blocked", "expired", "done", "cancelled"].includes(t.status))
    acts.push('<button class="btn" data-act="retry" data-id="' + t.id + '">Relancer</button>');
  if (["queued", "blocked"].includes(t.status))
    acts.push('<button class="btn danger" data-act="cancel" data-id="' + t.id + '">Annuler</button>');
  acts.push('<button class="btn" data-act="logs" data-id="' + t.id + '">Journal</button>');
  return '<div class="detail">' +
    '<div class="cmd"><pre>' + esc(t.target) + "</pre></div>" +
    (kv.length ? '<dl class="kv">' + kv.join("") + "</dl>" : "") +
    '<div class="acts">' + acts.join("") + "</div>" +
    '<pre class="logs" data-id="' + t.id + '" hidden></pre></div>';
}

function tasks(s) {
  const q = (s.queue || []).filter(matches);
  if (!q.length) {
    $("list").innerHTML = '<li class="empty">' + ((s.queue || []).length ?
      "Aucune tâche ne correspond à ce filtre." : "File vide, rien en attente.") + "</li>";
    return;
  }
  $("list").innerHTML = q.map((t) => {
    const flags = [];
    if (t.while_busy) flags.push("while-busy");
    if (t.needs_absence) flags.push("absence");
    if (t.llm_cost && t.llm_cost !== "none") flags.push("llm " + t.llm_cost);
    if (t.attempts) flags.push(t.attempts + " essais");
    return '<li class="task ' + esc(t.status) + (open.has(t.id) ? " open" : "") + '" data-id="' + t.id + '">' +
      '<button class="row" data-act="toggle" data-id="' + t.id + '" aria-expanded="' + open.has(t.id) + '">' +
        '<span class="head"><span class="tid">#' + t.id + '</span>' +
        '<span class="badge ' + esc(t.status) + '">' + (LBL[t.status] || t.status) + "</span>" +
        '<span class="prio">P' + t.priority + "</span></span>" +
        '<span class="chev">›</span>' +
        '<span class="target">' + esc(t.target) + "</span>" +
        '<span class="meta"><span class="m">' + esc(when(t)) + "</span>" +
          (flags.length ? '<span class="m"><b>' + esc(flags.join(" · ")) + "</b></span>" : "") +
          '<span class="m"><b>' + esc(t.assigned_host || "local") + "</b></span>" +
        "</span></button>" +
      (open.has(t.id) ? detail(t) : "") + "</li>";
  }).join("");
  for (const id of open) {
    const pre = document.querySelector('.logs[data-id="' + id + '"]');
    const cached = LOGS.get(id);
    if (pre && cached) { pre.hidden = false; pre.textContent = cached; }
  }
}

function decisions(s) {
  const ds = s.decisions || [];
  $("declabel").textContent = "Décisions récentes · " + ds.length;
  $("dec").innerHTML = ds.map((d) =>
    '<li><span class="t">' + esc(d.at) + '</span><span class="a ' + esc(d.action) + '">' + esc(d.action) +
    '</span><span class="r">' + (d.task_id ? '<b>#' + d.task_id + "</b> " : "") + esc(d.reason) +
    ' <span class="who">(' + esc(d.actor) + ")</span></span></li>").join("");
}

function render(s) {
  DATA = s;
  const c = s.counts || {};
  document.title = (c.queued || 0) + (c.running ? "+" + c.running : "") + " · taskq";
  const tog = $("toggle");
  tog.textContent = s.paused ? "Reprendre" : "Pause";
  tog.className = "btn " + (s.paused ? "go" : "warn");
  const ack = $("ack");
  if (s.unacked > 0) { ack.hidden = false; ack.innerHTML = "Lu <b>" + s.unacked + "</b>"; }
  else ack.hidden = true;
  tiles(s); fleet(s); chips(s); tasks(s); decisions(s);
  $("stamp").textContent = (s.paused ? "file en pause · " : "") + "actualisé " + s.now.slice(11, 19);
  $("dot").className = "dot";
  $("foot").textContent = "API locale 9077 · MAJ " + s.now.slice(0, 10);
}

async function tick() {
  try {
    const r = await fetch("/api/state", { cache: "no-store" });
    if (!r.ok) throw new Error(r.status);
    const s = await r.json();
    const h = JSON.stringify(s);
    if (h !== HASH) { HASH = h; render(s); }
    else { $("stamp").textContent = (s.paused ? "file en pause · " : "") + "actualisé " + s.now.slice(11, 19); }
  } catch (e) {
    $("stamp").textContent = "hors ligne (" + e.message + ")";
    $("dot").className = "dot off";
  }
}

async function loadLogs(id) {
  const pre = document.querySelector('.logs[data-id="' + id + '"]');
  if (!pre) return;
  pre.hidden = false;
  if (LOGS.has(id)) { pre.textContent = LOGS.get(id) || "(vide)"; return; }
  pre.textContent = "chargement du journal…";
  try {
    const r = await fetch("/api/logs?id=" + id + "&lines=250", { cache: "no-store" });
    const j = await r.json();
    const out = j.ok ? (j.log || "(journal vide pour cette tâche)") : "erreur: " + (j.error || j.err || r.status);
    LOGS.set(id, out);
    pre.textContent = out;
  } catch (e) { pre.textContent = "erreur réseau"; }
}

document.addEventListener("click", (e) => {
  const el = e.target.closest("[data-act]");
  if (!el) return;
  const id = el.dataset.id ? Number(el.dataset.id) : undefined;
  const a = el.dataset.act;
  if (a === "toggle") {
    if (open.has(id)) open.delete(id); else open.add(id);
    tasks(DATA);
  } else if (a === "logs") {
    loadLogs(id);
  } else if (a === "retry" || a === "cancel") {
    act(a, id);
  }
});
$("chips").addEventListener("click", (e) => {
  const b = e.target.closest(".chip");
  if (!b) return;
  filt = b.dataset.f;
  chips(DATA); tasks(DATA);
});
$("search").addEventListener("input", (e) => { txt = e.target.value.trim(); tasks(DATA); });
$("toggle").addEventListener("click", () => {
  if (!DATA) return;
  act(DATA.paused ? "resume" : "pause");
});
$("ack").addEventListener("click", () => act("ack"));
$("decbtn").addEventListener("click", () => {
  const b = $("decbtn"), d = $("dec");
  const openNow = b.getAttribute("aria-expanded") === "true";
  b.setAttribute("aria-expanded", String(!openNow));
  d.hidden = openNow;
});
window.addEventListener("beforeinstallprompt", (e) => {
  e.preventDefault(); installEvt = e; $("install").hidden = false;
});
$("install").addEventListener("click", async () => {
  $("install").hidden = true;
  if (installEvt) { installEvt.prompt(); installEvt = null; }
});

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => navigator.serviceWorker.register("/sw.js").catch(() => {}));
}
setInterval(() => { if (!document.hidden) tick(); }, 5000);
document.addEventListener("visibilitychange", () => { if (!document.hidden) tick(); });
tick();
</script>
</body>
</html>
"""

MANIFEST = """{
  "name": "taskq",
  "short_name": "taskq",
  "description": "File de taches lourdes de tower",
  "lang": "fr",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "orientation": "portrait-primary",
  "background_color": "#1e1e2e",
  "theme_color": "#1e1e2e",
  "icons": [
    { "src": "/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any" }
  ]
}
"""

SW = """// taskq service worker : coquille hors ligne, reseau prioritaire.
// L'API n'est jamais cachee : l'etat doit rester frais.
const CACHE = "taskq-v1";
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.pathname.startsWith("/api/")) return;
  e.respondWith(
    fetch(e.request)
      .then((r) => {
        const copy = r.clone();
        caches.open(CACHE).then((c) => c.put(e.request, copy)).catch(() => {});
        return r;
      })
      .catch(() => caches.match(e.request).then((r) => r || caches.match("/")))
  );
});
"""

ICON = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <rect width="32" height="32" rx="8" fill="#1e1e2e"/>
  <rect x="0.5" y="0.5" width="31" height="31" rx="7.5" fill="#181825" stroke="#45475a"/>
  <path d="M9 11.5h14M9 16h9M9 20.5h11" stroke="#b4befe" stroke-width="2" stroke-linecap="round" fill="none"/>
  <circle cx="24" cy="20.5" r="2.4" stroke="#b4befe" stroke-width="2" fill="none"/>
</svg>
"""

ASSETS = {
    "/manifest.webmanifest": ("application/manifest+json; charset=utf-8", MANIFEST),
    "/sw.js": ("text/javascript; charset=utf-8", SW),
    "/icon.svg": ("image/svg+xml; charset=utf-8", ICON),
}


class Handler(BaseHTTPRequestHandler):
    server_version = "taskq-api"

    def _send(self, code: int, ctype: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, payload) -> None:
        self._send(code, "application/json; charset=utf-8", json.dumps(payload, default=str).encode())

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        worker = bool(getattr(self.server, "worker_only", False))
        try:
            if worker:
                if path == "/worker/healthz":
                    self._json(200, {"status": "ok", "role": "worker-api"})
                else:
                    self._json(404, {"ok": False, "error": "not found"})
                return
            if path == "/":
                self._send(200, "text/html; charset=utf-8", PAGE.encode())
            elif path in ASSETS:
                ctype, text = ASSETS[path]
                self._send(200, ctype, text.encode())
            elif path == "/api/state":
                self._json(200, state())
            elif path == "/api/logs":
                self._json(200, logs(int(query(self.path, "id", "0") or 0),
                                     int(query(self.path, "lines", "200") or 200)))
            elif path == "/api/healthz":
                self._json(200, {"status": "ok"})
            else:
                self._json(404, {"ok": False, "error": "not found"})
        except Exception as e:  # une erreur ne doit pas tuer le serveur
            self._json(500, {"ok": False, "error": repr(e)})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        worker = bool(getattr(self.server, "worker_only", False))
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            body = None
        # Routes de flotte : uniquement sur le listener dedie, jeton par hote.
        if path.startswith("/worker/"):
            if not worker:
                self._json(404, {"ok": False, "error": "not found"})
                return
            name = host_of(self.headers.get("Authorization"))
            if not name:
                self._json(401, {"ok": False, "error": "jeton de worker inconnu"})
                return
            if not isinstance(body, dict):
                self._json(400, {"ok": False, "error": "corps JSON invalide"})
                return
            fn = {"/worker/beat": worker_beat, "/worker/report": worker_report}.get(path)
            if fn is None:
                self._json(404, {"ok": False, "error": "not found"})
                return
            try:
                self._json(200, fn(name, body))
            except Exception as e:
                log(f"{path} ({name}) a echoue: {e!r}")
                self._json(500, {"ok": False, "error": repr(e)})
            return
        if worker or path != "/api/action" or not isinstance(body, dict):
            self._json(404, {"ok": False, "error": "not found"})
            return
        try:
            self._json(200, action(body))
        except Exception as e:
            self._json(500, {"ok": False, "error": repr(e)})

    def log_message(self, fmt: str, *args) -> None:
        log("%s %s" % (self.address_string(), fmt % args))


def serve(host: str, port: int, worker_only: bool) -> ThreadingHTTPServer:
    srv = ThreadingHTTPServer((host, port), Handler)
    srv.worker_only = worker_only  # type: ignore[attr-defined]
    return srv


def main() -> None:
    log(f"taskq-api sur {BIND}:{PORT}")
    if WORKER_BIND == BIND and WORKER_PORT == PORT:
        log("listener worker desactive: meme adresse que l'API webui")
    else:
        log(f"taskq worker-api sur {WORKER_BIND}:{WORKER_PORT} "
            f"(jetons {TOKENS_FILE}, bail {LEASE_S} s)")
        threading.Thread(
            target=serve, args=(WORKER_BIND, WORKER_PORT, True), daemon=True
        ).start()
        threading.Thread(target=reaper_loop, daemon=True).start()
    serve(BIND, PORT, False).serve_forever()


if __name__ == "__main__":
    main()
