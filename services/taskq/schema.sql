-- taskq : file de taches durable pour tower (Postgres, pattern SKIP LOCKED).
-- Tout est idempotent : le service systemd rejoue ce fichier a chaque rebuild.

create table if not exists tasks (
  id            bigserial primary key,
  key           text unique,                      -- cle d'idempotence (une seule ligne par tache planifiee)
  kind          text not null default 'systemd_unit',   -- systemd_unit | command
  target        text not null,                    -- nom d'unite systemd, ou commande shell
  run_as        text not null default 'hermes',   -- utilisateur pour kind=command
  workdir       text,
  env           jsonb not null default '{}'::jsonb,

  -- enveloppe de ressources : ce que la tache demande pour tourner
  cpu_class     text not null default 'medium'    -- light | medium | heavy
                check (cpu_class in ('light','medium','heavy')),
  mem_min_mb    int  not null default 512,        -- RAM libre exige pour demarrer
  gpu           boolean not null default false,
  llm_cost      text not null default 'none'      -- none | free | paid
                check (llm_cost in ('none','free','paid')),
  est_minutes   int,                              -- duree estimee (planification/notif)
  paid_cap_cents int not null default 0,          -- budget payant max consomme par cette tache

  -- ordonnancement
  priority      int not null default 100,         -- plus petit = plus urgent
  not_before    timestamptz not null default now(),
  deadline      timestamptz,                      -- au-dela, demarrage force puis 'expired'
  while_busy    boolean not null default false,   -- peut tourner pendant que marc utilise la machine
  needs_absence boolean not null default false,   -- ne tourne QUE pendant une absence de marc :
                                                  -- fenetre sommeil/travail de presence.py, ou
                                                  -- inactivite 15 min (hermes/ssh/webui) ; elle
                                                  -- est interrompue des qu'il revient
  requires_gpu  boolean not null default false,   -- si pas de GPU : 'blocked' au lieu de 'queued'

  status        text not null default 'queued'
                check (status in ('queued','running','done','failed','cancelled','expired','blocked')),
  attempts      int not null default 0,
  max_attempts  int not null default 2,
  unit          text,                             -- unité transitoire réellement lancée
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

-- Idempotent pour une table deja creee avant l'ajout de la colonne.
alter table tasks add column if not exists needs_absence boolean not null default false;

-- Journal des decisions du dispatcher et du cerveau : ce qui a ete fait, quand,
-- pourquoi, avec les metriques du moment. Sert aussi de file de notification.
create table if not exists decisions (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  task_id    bigint references tasks(id) on delete set null,
  action     text not null,        -- submit|start|finish|fail|defer|skip|expire|block|pause|resume|note
  actor      text not null default 'dispatcher',
  reason     text,                 -- en clair, pour marc
  metrics    jsonb,
  notified   boolean not null default false
);
create index if not exists decisions_pending_idx on decisions (notified, at desc);

-- Etat courant / reglages (pause globale, budgets, dernieres metriques).
create table if not exists state (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

-- presence_overrides : {date ISO -> {kind: off|wfh, note, by, at}} ; pose par
-- `taskq presence off|wfh|clear` (jour de conge ou de teletravail), lu par le
-- dispatcher a chaque tour (pas de rebuild pour un jour exceptionnel).
insert into state (key, value) values
  ('paused', 'false'::jsonb),
  ('paid_budget_cents_per_day', '300'::jsonb),
  ('paid_spent_today', '{"day": null, "cents": 0}'::jsonb),
  ('presence_overrides', '{}'::jsonb)
on conflict (key) do nothing;

-- ------------------------------------------------------------------ flotte
-- Workers enregistres (un par hote). Vide tant que la flotte n'est pas
-- branchee : le master (tower) est un worker local implicite, sans ligne.
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

-- Champs de la flotte sur les taches : le dispatcher les remplit quand il
-- vise un worker distant ; les taches sans `requires` restent executables en
-- local par le dispatcher (comportement actuel).
alter table tasks add column if not exists assigned_host text;
alter table tasks add column if not exists requires text[] not null default '{}';
alter table tasks add column if not exists lease_expires_at timestamptz;
-- Nombre de fois ou un worker a lache la tache en cours de route (bail expire).
-- Croise avec MAX_LEASE_LOSSES dans api.py : au-dela, la tache est abandonnee
-- au lieu d'etre remise en file indefiniment sur un hote qui drop en boucle.
alter table tasks add column if not exists lease_losses int not null default 0;
create index if not exists tasks_assigned_idx
  on tasks (assigned_host, status)
  where status in ('queued', 'running');

-- Vue lisible pour le CLI, la webui et les digests (drop: une vue ne peut pas
-- renommer/reordonner ses colonnes via create or replace).
drop view if exists queue;
create view queue as
select id, status, priority, key, kind, target, cpu_class, mem_min_mb, llm_cost,
       est_minutes, not_before, deadline, while_busy, needs_absence, started_at, finished_at,
       round(extract(epoch from (coalesce(finished_at, now()) - started_at)) / 60.0, 1) as minutes_taken,
       attempts, exit_code, left(coalesce(note, ''), 60) as note, created_at,
       assigned_host, lease_expires_at
from tasks
order by (status = 'running') desc, priority, created_at;
