//! Postgres storage: the service's memory (one row per minute) and graph
//! reads. The `presence` database is declared by the Nix module (ensureDatabases),
//! the schema by `schema.sql`. Local connection, no password: the `presence`
//! role is in trust mode on the loopback (flake rule).
//!
//! Why Postgres and not JSONL files: the activity log is a
//! time series that we query (24 h, typical week, CPU while marc
//! is there), and a file forces you to re-read everything to answer. The files
//! are still written for now (devices.json / forecast.json), because the
//! CPU governor and the taskq queue read them: those are small stable
//! contracts, not logs.
use serde_json::Value;

pub fn url() -> String {
    std::env::var("PRESENCE_PG")
        .unwrap_or_else(|_| "postgresql://presence@127.0.0.1:5432/presence".to_string())
}

fn connect() -> Result<postgres::Client, String> {
    // `Client::connect` et pas `Config::connect` : la construction manuelle
    // d'une Config paniquait dans postgres 0.19 (config.rs:465) et, avec
    // panic=abort, tuait le service a chaque lecture du graphe.
    let mut cli = std::panic::catch_unwind(|| {
        postgres::Client::connect(&url(), postgres::NoTls)
    })
    .map_err(|_| "postgres: panique a la connexion".to_string())?
    .map_err(|e| e.to_string())?;
    // never block the tick on a lock
    let _ = cli.simple_query("set statement_timeout = '4s'");
    Ok(cli)
}

/// Inserts the sample for the minute (idempotent).
pub fn insert_sample(snap: &Value) -> Result<(), String> {
    let mut cli = connect()?;
    let t = snap["epoch"].as_i64().unwrap_or(0);
    let cpu = &snap["_cpu"];
    let user = cpu["user"].as_f64();
    let top = cpu["top"].as_f64();
    let top_unit = cpu["top_unit"].as_str();
    cli.execute(
        "insert into samples (t, state, device, loc, reserve, cpu_user, cpu_top, top_unit, hermes_msg_15m, raw)
         values (to_timestamp($1), $2, $3, $4, $5, $6, $7, $8, $9, $10::text::jsonb)
         on conflict (t) do nothing",
        &[
            &(t as f64),
            &snap["presence"]["state"].as_str(),
            &snap["devices"]["active_device"].as_str(),
            &snap["devices"]["location"].as_str(),
            &snap["forecast"]["reserve"].as_bool(),
            &user.map(|v| v as f32),
            &top.map(|v| v as f32),
            &top_unit,
            &snap["hermes"]["messages_15m"].as_i64().map(|v| v as i32),
            &snap.to_string(),
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// Records a forecast (every 5 min, one row per instant).
pub fn insert_forecast(snap: &Value) -> Result<(), String> {
    let mut cli = connect()?;
    let f = &snap["forecast"];
    let at = f["at"].as_i64().unwrap_or(0);
    cli.execute(
        "insert into forecasts (at, reserved, p_now, p_next_30, why, payload)
         values (to_timestamp($1), $2, $3, $4, $5, $6::text::jsonb)
         on conflict (at) do nothing",
        &[
            &(at as f64),
            &f["reserve"].as_bool(),
            &f["p_now"].as_f64().map(|v| v as f32),
            &f["p_next_30"].as_f64().map(|v| v as f32),
            &f["why"].as_str(),
            &f.to_string(),
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub struct Row {
    pub t: i64,
    pub state: Option<String>,
    pub device: Option<String>,
    pub loc: Option<String>,
    pub reserve: Option<bool>,
    pub cpu_user: Option<f32>,
    pub cpu_top: Option<f32>,
    pub top_unit: Option<String>,
}

/// Samples from the last `hours` hours, oldest first.
pub fn samples_since(hours: i64) -> Result<Vec<Row>, String> {
    let mut cli = connect()?;
    let rows = cli
        .query(
            "select extract(epoch from t)::bigint, state, device, loc, reserve,
                    cpu_user, cpu_top, top_unit
             from samples where t > now() - make_interval(hours => $1) order by t",
            &[&(hours as i32)],
        )
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|r| Row {
            t: r.try_get(0).unwrap_or(0),
            state: r.try_get(1).unwrap_or(None),
            device: r.try_get(2).unwrap_or(None),
            loc: r.try_get(3).unwrap_or(None),
            reserve: r.try_get(4).unwrap_or(None),
            cpu_user: r.try_get(5).unwrap_or(None),
            cpu_top: r.try_get(6).unwrap_or(None),
            top_unit: r.try_get(7).unwrap_or(None),
        })
        .collect())
}

/// Database state, for /healthz and diagnostics.
pub fn health() -> Value {
    match connect() {
        Ok(mut cli) => match cli.query_one(
            "select (select count(*) from samples),
                    (select count(*) from samples where t > now() - interval '24 hours'),
                    (select count(*) from forecasts),
                    (select extract(epoch from max(t))::float8 from samples)",
            &[],
        ) {
            // try_get partout : une colonne NULL ou d'un type inattendu doit
            // donner une valeur absente, jamais une panique (un panic dans le
            // thread du ticker arretait toutes les sondes).
            Ok(r) => serde_json::json!({
                "ok": true,
                "samples_total": r.try_get::<_, i64>(0).unwrap_or(0),
                "samples_24h": r.try_get::<_, i64>(1).unwrap_or(0),
                "forecasts": r.try_get::<_, i64>(2).unwrap_or(0),
                "last_sample": r.try_get::<_, Option<f64>>(3).unwrap_or(None),
            }),
            Err(e) => serde_json::json!({"ok": false, "error": e.to_string()}),
        },
        Err(e) => serde_json::json!({"ok": false, "error": e}),
    }
}
