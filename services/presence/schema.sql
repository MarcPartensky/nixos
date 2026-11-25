-- Schema of the presence service (Rust). Idempotent: replayed on each switch.
-- One row per minute in `samples`: it is the model's memory (habits,
-- CPU of background tasks when marc is there or away) and the source of the graph.
create table if not exists samples (
    t               timestamptz primary key,
    state           text,
    device          text,          -- active device (mac / phone / tower / null)
    loc             text,          -- home / work / out / out? / unknown
    reserve         boolean,       -- was the machine reserved for marc
    cpu_user        real,          -- cores consumed by human sessions + agent
    cpu_top         real,          -- biggest system job of the minute
    top_unit        text,
    hermes_msg_15m  integer,       -- Hermes user messages over 15 min
    raw             jsonb
);

create index if not exists samples_t_idx on samples (t desc);

-- One row per forecast computation: lets you compare what was predicted
-- with what happened next (model quality).
create table if not exists forecasts (
    at          timestamptz primary key,
    reserved    boolean,
    p_now       real,
    p_next_30   real,
    why         text,
    payload     jsonb
);

create index if not exists forecasts_at_idx on forecasts (at desc);
