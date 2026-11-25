-- mnemo: scoring, gaps and briefs for Marc's conversations.
-- Idempotent: applied at every activation, never drops anything.

create table if not exists session_score (
  id          text primary key,          -- Hermes session id
  source      text,
  title       text,
  started_at  double precision,
  sujet       text,
  objectif    text,
  domaine     text,
  matiere     integer,
  points      integer,
  ignorance   integer,
  importance  integer,
  focus       boolean,
  points_liste text,
  priorite    double precision,
  model       text,
  scored_at   double precision default extract(epoch from now())
);
create index if not exists session_score_priorite on session_score (priorite desc);

create table if not exists gap (
  id          bigserial primary key,
  session_id  text references session_score(id) on delete cascade,
  point       text not null,
  quote       text,
  explanation text,
  created_at  double precision default extract(epoch from now()),
  unique (session_id, point)
);

create table if not exists brief (
  session_id      text primary key references session_score(id) on delete cascade,
  title           text,
  summary         text,
  body            text,
  reading_minutes integer,
  terms           text[] default '{}',
  written_at      double precision default extract(epoch from now())
);

-- One row per outbound delivery, so a re-run never publishes twice.
create table if not exists publish (
  id          bigserial primary key,
  session_id  text not null,
  channel     text not null,             -- podcast | typer
  reference   text,
  at          double precision default extract(epoch from now()),
  unique (session_id, channel)
);

create or replace view v_backlog as
  select s.priorite, s.id, s.sujet, s.domaine, s.importance, s.points,
         (b.session_id is not null) as has_brief
  from session_score s
  left join brief b on b.session_id = s.id
  order by s.priorite desc;
