-- taskq: durable task queue for tower (Postgres, SKIP LOCKED pattern).
-- Everything is idempotent: the systemd service replays this file on every rebuild.

create table if not exists tasks (
  id            bigserial primary key,
  key           text unique,                      -- idempotency key (a single row per scheduled task)
  kind          text not null default 'systemd_unit',   -- systemd_unit | command
  target        text not null,                    -- name of a systemd unit, or shell command
  run_as        text not null default 'hermes',   -- user for kind=command
  workdir       text,
  env           jsonb not null default '{}'::jsonb,

  -- resource envelope: what the task asks for in order to run
  cpu_class     text not null default 'medium'    -- light | medium | heavy
                check (cpu_class in ('light','medium','heavy')),
  mem_min_mb    int  not null default 512,        -- free RAM required to start
  gpu           boolean not null default false,
  llm_cost      text not null default 'none'      -- none | free | paid
                check (llm_cost in ('none','free','paid')),
  est_minutes   int,                              -- estimated duration (scheduling/notif)
  paid_cap_cents int not null default 0,          -- max paid budget consumed by this task

  -- scheduling
  priority      int not null default 100,         -- smaller = more urgent
  not_before    timestamptz not null default now(),
  deadline      timestamptz,                      -- beyond it, forced start then 'expired'
  while_busy    boolean not null default false,   -- can run while marc is using the machine
  needs_absence boolean not null default false,   -- runs ONLY during an absence of marc:
                                                  -- sleep/work window of presence.py, or
                                                  -- 15 min inactivity (hermes/ssh/webui); it
                                                  -- is interrupted as soon as he comes back
  requires_gpu  boolean not null default false,   -- if no GPU: 'blocked' instead of 'queued'

  status        text not null default 'queued'
                check (status in ('queued','running','done','failed','cancelled','expired','blocked')),
  attempts      int not null default 0,
  max_attempts  int not null default 2,
  unit          text,                             -- transient unit actually started
  started_at    timestamptz,
  finished_at   timestamptz,
  exit_code     int,
  note          text,
  result        jsonb,

  created_by    text default current_user,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists tasks_ready_idx
  on tasks (priority, not_before)
  where status = 'queued';
create index if not exists tasks_running_idx
  on tasks (status)
  where status = 'running';
create index if not exists tasks_recent_idx on tasks (created_at desc);

-- Idempotent for a table already created before the column was added.
alter table tasks add column if not exists needs_absence boolean not null default false;

-- Log of the dispatcher's and the brain's decisions: what was done, when,
-- why, with the metrics of the moment. Also serves as a notification queue.
create table if not exists decisions (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  task_id    bigint references tasks(id) on delete set null,
  action     text not null,        -- submit|start|finish|fail|defer|skip|expire|block|pause|resume|note
  actor      text not null default 'dispatcher',
  reason     text,                 -- in plain language, for marc
  metrics    jsonb,
  notified   boolean not null default false
);
create index if not exists decisions_pending_idx on decisions (notified, at desc);

-- Current state / settings (global pause, budgets, latest metrics).
create table if not exists state (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

-- presence_overrides: {ISO date -> {kind: off|wfh, note, by, at}}; set by
-- `taskq presence off|wfh|clear` (day off or remote work), read by the
-- dispatcher on each round (no rebuild for an exceptional day).
insert into state (key, value) values
  ('paused', 'false'::jsonb),
  ('paid_budget_cents_per_day', '300'::jsonb),
  ('paid_spent_today', '{"day": null, "cents": 0}'::jsonb),
  ('presence_overrides', '{}'::jsonb)
on conflict (key) do nothing;

-- ------------------------------------------------------------------ fleet
-- Registered workers (one per host). Empty as long as the fleet is not
-- wired up: the master (tower) is an implicit local worker, without a row.
create table if not exists hosts (
  name              text primary key,               -- tower | deck | anywhere | mac
  caps              jsonb not null default '{}'::jsonb,  -- {tor, renderer, s3, google_egress, always_on, gpu}
  metrics           jsonb not null default '{}'::jsonb,  -- load, mem_avail_mb, battery, on_ac, awake, ...
  enabled           boolean not null default true,
  quarantined_until timestamptz,
  note              text,
  first_seen        timestamptz not null default now(),
  heartbeat         timestamptz
);

-- Fleet fields on tasks: the dispatcher fills them when it
-- targets a remote worker; tasks without `requires` stay executable
-- locally by the dispatcher (current behavior).
alter table tasks add column if not exists assigned_host text;
alter table tasks add column if not exists requires text[] not null default '{}';
alter table tasks add column if not exists lease_expires_at timestamptz;
-- Number of times a worker dropped the task along the way (expired lease).
-- Crossed with MAX_LEASE_LOSSES in api.py: beyond it, the task is abandoned
-- instead of being requeued indefinitely on a host that keeps dropping.
alter table tasks add column if not exists lease_losses int not null default 0;
create index if not exists tasks_assigned_idx
  on tasks (assigned_host, status)
  where status in ('queued', 'running');

-- Readable view for the CLI, the webui and the digests (drop: a view cannot
-- rename/reorder its columns via create or replace).
drop view if exists queue;
create view queue as
select id, status, priority, key, kind, target, cpu_class, mem_min_mb, llm_cost,
       est_minutes, not_before, deadline, while_busy, needs_absence, started_at, finished_at,
       round(extract(epoch from (coalesce(finished_at, now()) - started_at)) / 60.0, 1) as minutes_taken,
       attempts, exit_code, left(coalesce(note, ''), 60) as note, created_at,
       assigned_host, lease_expires_at
from tasks
order by (status = 'running') desc, priority, created_at;
