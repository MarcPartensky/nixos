#!/usr/bin/env python3
"""taskq-api: JSON API + webui for tower's task queue.

Zero dependency (stdlib + psql, like the dispatcher). Listens on loopback
only: remote access goes through Pangolin (SSO) -> newt -> 127.0.0.1.

  GET  /              -> the webui (single page, 5 s poll of /api/state)
  GET  /api/state     -> JSON snapshot (queue, decisions, hosts, metrics)
  GET  /api/healthz   -> {"status":"ok"} (Pangolin healthcheck)
  POST /api/action    -> {"action": pause|resume|ack|unblock|cancel|retry, "id": n}

The actions are those of the `taskq` CLI (same SQL, actor "webui" in
`decisions`). The fleet protocol (/worker/*, tokens) will land here, under the
same unit, with per-host authentication.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import threading
import time
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
        exec_(f"insert into decisions (action, actor, reason) values ('pause', {q(ACTOR)}, 'queue paused (webui)')")
    elif a == "resume":
        exec_("insert into state (key, value) values ('paused', 'false'::jsonb)"
              " on conflict (key) do update set value = 'false'::jsonb, updated_at = now()")
        exec_(f"insert into decisions (action, actor, reason) values ('resume', {q(ACTOR)}, 'queue resumed (webui)')")
    elif a == "ack":
        n = psql("update decisions set notified = true where not notified returning id")
        return {"ok": True, "action": a, "acked": n.count("\n") + 1 if n else 0}
    elif a == "unblock":
        exec_("update tasks set status='queued', note='unblocked', updated_at=now() where status='blocked'")
        exec_(f"insert into decisions (action, actor, reason) values ('unblock', {q(ACTOR)}, 'blocked tasks requeued (webui)')")
    elif a == "cancel":
        if tid is None:
            return {"ok": False, "error": "id required"}
        exec_(f"update tasks set status='cancelled', finished_at=now(), updated_at=now(),"
              f" note={q(reason or 'cancelled by webui')} where id={int(tid)} and status in ('queued', 'blocked')")
        exec_(f"insert into decisions (task_id, action, actor, reason) values ({int(tid)}, 'skip', {q(ACTOR)}, {q(reason or 'cancelled by webui')})")
    elif a == "retry":
        if tid is None:
            return {"ok": False, "error": "id required"}
        exec_(f"update tasks set status='queued', not_before=now(), attempts=0, updated_at=now() where id={int(tid)}")
        exec_(f"insert into decisions (task_id, action, actor, reason) values ({int(tid)}, 'note', {q(ACTOR)}, 'requeued (webui)')")
    else:
        return {"ok": False, "error": f"unknown action: {a or '(empty)'}"}
    log(f"action {a} {('#' + str(tid)) if tid is not None else ''}")
    return {"ok": True, "action": a}


# ------------------------------------------------------------------- fleet
# Fleet protocol: the remote workers (deck, laptop, anywhere, mac)
# call these routes in PULL mode. No port open on them, no local
# state data: the master keeps the policy (pause, budget, GPU) and the lease
# of each task. A host that goes silent (sleep, wifi, reboot) sees its lease
# expire and its task requeued by the reaper (thread below).

WORKER_BIND = os.environ.get("TASKQ_WORKER_BIND", "127.0.0.1")
WORKER_PORT = int(os.environ.get("TASKQ_WORKER_PORT", "9078"))
TOKENS_FILE = os.environ.get("TASKQ_WORKER_TOKENS", "/etc/taskq/worker-tokens.json")
LEASE_S = int(os.environ.get("TASKQ_WORKER_LEASE", "120"))
MAX_LEASE_LOSSES = 5


def tokens() -> dict:
    """{hostname -> token}. File rendered by Nix from sops (0600)."""
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
    """Requeues the tasks whose worker went silent (expired lease)."""
    try:
        lost = rows(
            "with lost as ("
            " update tasks set status='queued', assigned_host=null,"
            "  lease_expires_at=null, lease_losses=lease_losses+1,"
            "  not_before=now() + interval '1 minute', updated_at=now(),"
            "  note='silent worker: expired lease, requeued'"
            " where status='running' and assigned_host is not null"
            "  and lease_expires_at < now()"
            " returning id, assigned_host, lease_losses)"
            " select id, assigned_host, lease_losses from lost"
        )
    except Exception as e:
        log(f"reaper: {e!r}")
        return
    for t in lost or []:
        log(f"expired lease: #{t['id']} lost by {t['assigned_host']}")
        exec_(
            "insert into decisions (task_id, action, actor, reason)"
            f" values ({int(t['id'])}, 'defer', 'reaper', "
            f"{q('host ' + str(t['assigned_host']) + ' silent: expired lease, task requeued')})"
        )
        if int(t["lease_losses"] or 0) >= MAX_LEASE_LOSSES:
            exec_(
                "update tasks set status='failed', finished_at=now(), updated_at=now(),"
                f" note={q('abandoned: ' + str(t['lease_losses']) + ' lost leases')}"
                f" where id={int(t['id'])}"
            )
            exec_(
                "insert into decisions (task_id, action, actor, reason)"
                f" values ({int(t['id'])}, 'fail', 'reaper', "
                f"{q('abandoned after ' + str(t['lease_losses']) + ' lost leases')})"
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
    # The lease renews on each beat: a long task lives as long as
    # the host beats, and dies as soon as it goes silent.
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
            why = "assigned to %s (%s load, %s MB free)" % (
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
        log(f"report #{tid} from {name} ignored (task no longer assigned)")
        return {"ok": True, "ignored": True}
    exec_(
        "insert into decisions (task_id, action, actor, reason)"
        f" values ({tid}, {q('finish' if status == 'done' else 'fail')}, "
        f"{q('worker:' + name)}, {q(note[:200])})"
    )
    log(f"#{tid} {status} on {name}")
    return {"ok": True, "id": tid, "status": status}


PAGE = r"""<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>taskq</title>
<style>
  :root{
    --base:#1e1e2e; --mantle:#181825; --crust:#11111b;
    --surface0:#313244; --surface1:#45475a; --overlay0:#6c7086;
    --text:#cdd6f4; --subtext:#a6adc8;
    --lavender:#b4befe; --green:#a6e3a1; --red:#f38ba8; --yellow:#f9e2af;
    --peach:#fab387; --sky:#89dceb; --blue:#89b4fa; --mauve:#cba6f7;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--base);color:var(--text);
       font:14px/1.45 system-ui,-apple-system,sans-serif}
  a{color:var(--lavender)}
  header{position:sticky;top:0;z-index:2;background:var(--mantle);
         border-bottom:1px solid var(--surface0);padding:14px 20px 12px}
  .top{display:flex;align-items:baseline;gap:14px;flex-wrap:wrap}
  h1{margin:0;font-size:20px;letter-spacing:.5px;color:var(--lavender)}
  .sub{color:var(--subtext);font-size:12px}
  .pills{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}
  .pill{border:1px solid var(--surface0);background:var(--crust);border-radius:999px;
        padding:3px 10px;font-size:12px;color:var(--subtext);white-space:nowrap}
  .pill b{color:var(--text);font-weight:600}
  .pill.ok b{color:var(--green)} .pill.warn b{color:var(--yellow)}
  .pill.bad b{color:var(--red)} .pill.info b{color:var(--sky)}
  .buttons{display:flex;gap:8px;margin-top:10px;flex-wrap:wrap}
  button{background:var(--surface0);color:var(--text);border:1px solid var(--surface1);
         border-radius:8px;padding:5px 12px;font-size:13px;cursor:pointer}
  button:hover{border-color:var(--lavender);color:var(--lavender)}
  button.danger:hover{border-color:var(--red);color:var(--red)}
  main{padding:18px 20px 40px;max-width:1280px}
  section{margin-bottom:22px}
  h2{font-size:12px;text-transform:uppercase;letter-spacing:1.2px;color:var(--overlay0);
     margin:0 0 8px;font-weight:600}
  table{width:100%;border-collapse:collapse;background:var(--mantle);
        border:1px solid var(--surface0);border-radius:10px;overflow:hidden}
  th{font-size:11px;text-transform:uppercase;letter-spacing:.8px;color:var(--overlay0);
     text-align:left;padding:7px 10px;border-bottom:1px solid var(--surface0);font-weight:600}
  td{padding:6px 10px;border-bottom:1px solid var(--crust);vertical-align:top;font-size:13px}
  tr:last-child td{border-bottom:none}
  .mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
  .st{display:inline-block;border-radius:6px;padding:1px 8px;font-size:11px;font-weight:600}
  .st.running{background:rgba(166,227,161,.15);color:var(--green)}
  .st.queued{background:rgba(180,190,254,.15);color:var(--lavender)}
  .st.blocked{background:rgba(249,226,175,.15);color:var(--yellow)}
  .st.failed{background:rgba(243,139,168,.15);color:var(--red)}
  .st.expired{background:rgba(250,179,135,.15);color:var(--peach)}
  .muted{color:var(--subtext)}
  .empty{color:var(--subtext);background:var(--mantle);border:1px dashed var(--surface0);
         border-radius:10px;padding:12px 14px;font-size:13px}
  ol.dec{margin:0;padding:0;list-style:none;background:var(--mantle);
         border:1px solid var(--surface0);border-radius:10px;overflow:hidden}
  ol.dec li{display:flex;gap:10px;padding:5px 12px;border-bottom:1px solid var(--crust);font-size:13px}
  ol.dec li:last-child{border-bottom:none}
  .act{min-width:74px;font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.6px;color:var(--lavender)}
  .act.start,.act.finish{color:var(--green)} .act.fail,.act.expire{color:var(--red)}
  .act.defer,.act.block{color:var(--yellow)} .act.pause{color:var(--peach)} .act.resume{color:var(--sky)}
  .t{color:var(--overlay0);font-family:ui-monospace,monospace;font-size:12px;min-width:62px}
  .r{color:var(--subtext)}
  .rowbtns button{padding:2px 9px;font-size:12px;margin-right:6px}
  #conn{color:var(--red);font-size:12px}
</style>
</head>
<body>
<header>
  <div class="top">
    <h1>taskq</h1>
    <span class="sub">tower task queue · <span id="conn" class="muted">connected</span></span>
  </div>
  <div class="pills" id="pills"></div>
  <div class="buttons">
    <button id="btn-pause" onclick="act('pause')">Pause</button>
    <button id="btn-resume" onclick="act('resume')">Resume</button>
    <button onclick="act('unblock')">Unblock</button>
    <button onclick="act('ack')">Mark read</button>
    <button onclick="tick()">Refresh</button>
  </div>
</header>
<main>
  <section><h2>Hosts</h2><div id="hosts"></div></section>
  <section><h2>Queue</h2><div id="queue"></div></section>
  <section><h2>Recent decisions</h2><div id="decisions"></div></section>
</main>
<script>
"use strict";
const $ = (s) => document.getElementById(s);
const esc = (v) => String(v === null || v === undefined ? "" : v)
  .replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

async function act(action, id) {
  const body = { action };
  if (id !== undefined) body.id = id;
  $("conn").textContent = "sending " + action + "...";
  try {
    const r = await fetch("/api/action", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    if (!j.ok) $("conn").textContent = "error: " + (j.error || r.status);
  } catch (e) {
    $("conn").textContent = "network error";
  }
  tick();
}

function pill(label, value, cls) {
  return '<span class="pill ' + (cls || "") + '">' + label + " <b>" + esc(value) + "</b></span>";
}

function render(s) {
  $("conn").textContent = "updated " + s.now.slice(11, 19);
  const m = s.metrics || {};
  const b = s.budget || {};
  const pills = [];
  pills.push(pill("state", s.paused ? "PAUSED" : "active", s.paused ? "bad" : "ok"));
  pills.push(pill("load", (m.load1 ?? "?") + "/" + (m.threads ?? "?"), (m.load1 ?? 0) > 0.9 * (m.threads || 1) ? "warn" : ""));
  pills.push(pill("free RAM", (m.mem_avail_mb ?? "?") + " MB"));
  const pw = { at_tower: ["at the machine", "warn"], away_work: ["away (work)", "ok"],
               away_sleep: ["away (sleep)", "ok"], nearby: ["near tower", "info"] }[m.presence];
  const until = m.presence_until ? " until " + m.presence_until.slice(11, 16) : "";
  const marc = pw ? pw[0] + until : (m.marc_connected ? "connected" : (m.marc_busy ? "busy" : (m.marc_present ? "present, calm" : "absent")));
  pills.push(pill("marc", marc, pw ? pw[1] : (m.marc_connected ? "info" : (m.marc_busy ? "warn" : "ok"))));
  pills.push(pill("paid budget", (b.left_cents ?? "?") + " c left out of " + (b.cap_cents ?? "?")));
  pills.push(pill("GPU", m.gpu ? m.gpu : "none"));
  pills.push(pill("local model", m.local_model_running ? "running" : "no"));
  pills.push(pill("unread decisions", s.unacked, s.unacked > 0 ? "info" : ""));
  const c = s.counts || {};
  pills.push(pill("queue", (c.queued || 0) + " queued · " + (c.running || 0) + " running · " + (c.blocked || 0) + " blocked · " + (c.failed || 0) + " failed"));
  $("pills").innerHTML = pills.join("");

  const hs = s.hosts || [];
  if (!hs.length) {
    $("hosts").innerHTML = '<div class="empty">No remote worker registered. tower runs locally (implicit master and worker); the fleet (deck, anywhere, mac) will plug in here.</div>';
  } else {
    let h = "<table><tr><th>host</th><th>state</th><th>caps</th><th>load</th><th>free RAM</th><th>note</th></tr>";
    for (const x of hs) {
      const mx = x.metrics || {};
      const silent = x.silent_s;
      const st = !x.enabled ? ["disabled", "failed"] :
        (x.quarantined_until ? ["quarantine", "blocked"] :
        (silent >= 0 && silent < 90 ? ["online", "running"] : ["silent " + silent + " s", "blocked"]));
      h += "<tr><td class='mono'>" + esc(x.name) + "</td><td><span class='st " + st[1] + "'>" + st[0] + "</span></td>" +
           "<td class='mono'>" + esc(Object.keys(x.caps || {}).filter(k => x.caps[k]).join(", ") || "-") + "</td>" +
           "<td class='mono'>" + esc(mx.load1 ?? "-") + "</td><td class='mono'>" + esc(mx.mem_avail_mb ?? "-") + "</td>" +
           "<td class='muted'>" + esc(x.note || "") + "</td></tr>";
    }
    $("hosts").innerHTML = h + "</table>";
  }

  const q = s.queue || [];
  if (!q.length) {
    $("queue").innerHTML = '<div class="empty">Queue empty.</div>';
  } else {
    let h = "<table><tr><th>id</th><th>state</th><th>prio</th><th>class</th><th>target</th><th>host</th><th>detail</th><th></th></tr>";
    for (const t of q) {
      const when = t.status === "running" ? ("started " + esc(t.started) + " (" + esc(t.minutes_taken) + " min)") :
        (t.deadline ? ("deadline " + esc(t.deadline)) : ("ready " + esc(t.not_before)));
      const flags = [];
      if (t.while_busy) flags.push("while-busy");
      if (t.needs_absence) flags.push("absence");
      if (t.llm_cost && t.llm_cost !== "none") flags.push("llm " + t.llm_cost);
      if (t.attempts) flags.push("attempts " + t.attempts);
      const bits = [when].concat(flags);
      if (t.note) bits.push(esc(t.note));
      const btns = [];
      if (["failed", "blocked", "expired", "done", "cancelled"].includes(t.status)) btns.push("<button onclick=\"act('retry'," + t.id + ")\">Retry</button>");
      if (["queued", "blocked"].includes(t.status)) btns.push("<button class='danger' onclick=\"act('cancel'," + t.id + ")\">Cancel</button>");
      h += "<tr><td class='mono'>" + t.id + "</td>" +
           "<td><span class='st " + esc(t.status) + "'>" + esc(t.status) + "</span></td>" +
           "<td class='mono'>" + t.priority + "</td><td class='mono'>" + esc(t.cpu_class) + "</td>" +
           "<td class='mono'>" + esc(t.target) + "</td><td class='mono'>" + esc(t.assigned_host || "local") + "</td>" +
           "<td class='muted'>" + bits.join(" · ") + "</td>" +
           "<td class='rowbtns'>" + btns.join("") + "</td></tr>";
    }
    $("queue").innerHTML = h + "</table>";
  }

  const ds = s.decisions || [];
  if (!ds.length) {
    $("decisions").innerHTML = '<div class="empty">No decision.</div>';
  } else {
    let h = "<ol class='dec'>";
    for (const d of ds) {
      h += "<li><span class='t'>" + esc(d.at) + "</span><span class='act " + esc(d.action) + "'>" + esc(d.action) + "</span>" +
           "<span class='r'>" + (d.task_id ? ("#" + d.task_id + " ") : "") + esc(d.reason) + " <span class='muted'>(" + esc(d.actor) + ")</span></span></li>";
    }
    $("decisions").innerHTML = h + "</ol>";
  }
}

async function tick() {
  try {
    const r = await fetch("/api/state");
    if (!r.ok) throw new Error(r.status);
    render(await r.json());
  } catch (e) {
    $("conn").textContent = "offline (" + e.message + ")";
  }
}
setInterval(tick, 5000);
tick();
</script>
</body>
</html>
"""


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
            elif path == "/api/state":
                self._json(200, state())
            elif path == "/api/healthz":
                self._json(200, {"status": "ok"})
            else:
                self._json(404, {"ok": False, "error": "not found"})
        except Exception as e:  # an error must not kill the server
            self._json(500, {"ok": False, "error": repr(e)})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        worker = bool(getattr(self.server, "worker_only", False))
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            body = None
        # Fleet routes: only on the dedicated listener, per-host token.
        if path.startswith("/worker/"):
            if not worker:
                self._json(404, {"ok": False, "error": "not found"})
                return
            name = host_of(self.headers.get("Authorization"))
            if not name:
                self._json(401, {"ok": False, "error": "unknown worker token"})
                return
            if not isinstance(body, dict):
                self._json(400, {"ok": False, "error": "invalid JSON body"})
                return
            fn = {"/worker/beat": worker_beat, "/worker/report": worker_report}.get(path)
            if fn is None:
                self._json(404, {"ok": False, "error": "not found"})
                return
            try:
                self._json(200, fn(name, body))
            except Exception as e:
                log(f"{path} ({name}) failed: {e!r}")
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
    log(f"taskq-api on {BIND}:{PORT}")
    if WORKER_BIND == BIND and WORKER_PORT == PORT:
        log("worker listener disabled: same address as the webui API")
    else:
        log(f"taskq worker-api on {WORKER_BIND}:{WORKER_PORT} "
            f"(tokens {TOKENS_FILE}, lease {LEASE_S} s)")
        threading.Thread(
            target=serve, args=(WORKER_BIND, WORKER_PORT, True), daemon=True
        ).start()
        threading.Thread(target=reaper_loop, daemon=True).start()
    serve(BIND, PORT, False).serve_forever()


if __name__ == "__main__":
    main()
