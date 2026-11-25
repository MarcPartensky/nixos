-- Schema du service de presence (Rust). Idempotent : rejoue a chaque switch.
-- Une ligne par minute dans `samples` : c'est la memoire du modele (habitudes,
-- CPU des taches de fond quand marc est la ou absent) et la source du graphe.
create table if not exists samples (
    t               timestamptz primary key,
    state           text,
    device          text,          -- appareil actif (mac / phone / tower / null)
    loc             text,          -- home / work / out / out? / unknown
    reserve         boolean,       -- la machine etait-elle reservee pour marc
    cpu_user        real,          -- coeurs consommes par les sessions humaines + agent
    cpu_top         real,          -- plus gros job systeme de la minute
    top_unit        text,
    hermes_msg_15m  integer,       -- messages utilisateur Hermes sur 15 min
    raw             jsonb
);

create index if not exists samples_t_idx on samples (t desc);

-- Une ligne par calcul de prevision : permet de comparer ce qui a ete prevu
-- avec ce qui s'est passe ensuite (qualite du modele).
create table if not exists forecasts (
    at          timestamptz primary key,
    reserved    boolean,
    p_now       real,
    p_next_30   real,
    why         text,
    payload     jsonb
);

create index if not exists forecasts_at_idx on forecasts (at desc);
