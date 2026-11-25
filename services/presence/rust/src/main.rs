//! Presence service: probes + snapshot + forecast, serves /api/state.
//!
//! Built to cost almost nothing: one tick thread (2 s) that reads a few
//! files, two SSH probe threads that sleep between measurements, a
//! single-threaded tokio HTTP server that returns an already-serialized string.
mod automation;
mod conf;
mod model;
mod probes;
mod snapshot;
mod state;
mod store;
mod util;

use axum::{
    extract::State,
    http::StatusCode,
    response::{Html, IntoResponse},
    routing::{get, post},
    Json, Router,
};
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;

use state::Shared;
use util::{env_s, env_u};

const INDEX_HTML: &str = include_str!("../assets/index.html");

fn env_f(key: &str, def: f64) -> f64 {
    util::env_f(key, def)
}

/// Adds an `iso_local` field to the model (readable local time).
fn now_iso() -> String {
    format!("\"{}\"", model::iso_local(util::now())).trim_matches('"').to_string()
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let state_dir = env_s("PRESENCE_STATE_DIR", "/var/lib/hermes/presence-dashboard");
    let hermes_home = env_s("HERMES_HOME", "/var/lib/hermes");
    let host = env_s("PRESENCE_HOST", "0.0.0.0");
    let port = env_u("PRESENCE_PORT", 9143);
    let _ = std::fs::create_dir_all(&state_dir);
    let _ = std::fs::create_dir_all(format!("{state_dir}/ssh"));

    let sh = Arc::new(Shared::new(&state_dir));
    // initial model: built right away so that the page is not empty
    let model = model::build_model(std::path::Path::new(&hermes_home));
    let ctx = snapshot::Ctx {
        sh: sh.clone(),
        windows: model::load_windows(),
        overrides: model::load_overrides(),
        model: Some(model),
        model_at: util::now(),
        hermes_home: hermes_home.clone(),
        hint_fresh: env_u("PRESENCE_HINT_FRESH", 180) as i64,
        conf: conf::load(&state_dir),
    };

    // history reloaded at startup (24 h)
    {
        let path = format!("{state_dir}/history.jsonl");
        if let Some(txt) = util::read(&path) {
            let mut hist: Vec<Value> = Vec::new();
            for line in txt.lines().rev().take(1500).collect::<Vec<_>>().into_iter().rev() {
                if let Ok(v) = serde_json::from_str::<Value>(line) {
                    hist.push(v);
                }
            }
            *sh.history.lock().unwrap() = hist;
        }
    }

    // ---- probes (blocking threads, sleeping between measurements)
    {
        let sh = sh.clone();
        let every = env_f("PRESENCE_MAC_EVERY", 8.0);
        let every_off = env_f("PRESENCE_MAC_EVERY_OFFLINE", 60.0);
        std::thread::spawn(move || loop {
            probes::probe_mac(&sh);
            let online = sh.mac.lock().unwrap().b("online");
            let d = if online { every } else { every_off };
            std::thread::sleep(Duration::from_secs_f64(d));
        });
    }
    {
        let sh = sh.clone();
        let every = env_f("PRESENCE_PHONE_EVERY", 180.0);
        std::thread::spawn(move || loop {
            probes::probe_phone(&sh);
            std::thread::sleep(Duration::from_secs_f64(every));
        });
    }
    {
        let sh = sh.clone();
        let every = env_f("PRESENCE_NET_EVERY", 60.0);
        std::thread::spawn(move || loop {
            probes::probe_tailscale(&sh);
            std::thread::sleep(Duration::from_secs_f64(every));
        });
    }

    // ---- tick: snapshot, HTTP cache, persistence
    {
        let sh = sh.clone();
        let mut ctx = ctx;
        let tick = env_f("PRESENCE_TICK", 2.0);
        let history_every = env_u("PRESENCE_HISTORY_SECONDS", 60) as i64;
        let sample_every = env_u("PRESENCE_SAMPLE_SECONDS", 5) as i64;
        let mut cpu = model::CpuSampler::default();
        let mut last_hist = 0i64;
        let mut last_sample = 0i64;
        let mut last_activity = 0i64;
        let mut last_pg = 0i64;
        let mut last_forecast_pg = 0i64;
        let mut last_timeline = 0i64;
        std::thread::spawn(move || {
            let mut last: Option<Value> = None;
            loop {
                let snap = snapshot::build(&mut ctx);
                let t = util::now();
                if last.is_none() || t - last_sample >= sample_every {
                    last_sample = t;
                    last = Some(snap.clone());
                    let body = snap.to_string();
                    let html = INDEX_HTML.replace(
                        "<!--SNAP-->",
                        &format!(
                            "<script>window.__SNAP__={};</script>",
                            body.replace("</", "<\\/")
                        ),
                    );
                    let mut c = sh.cached.write().unwrap();
                    c.body = body;
                    c.html = html;
                }
                if t - last_hist >= history_every {
                    last_hist = t;
                    let line = serde_json::json!({
                        "t": t,
                        "state": snap["presence"]["state"],
                        "connected": snap["hermes"]["connected"],
                        "device": snap["devices"]["active_device"],
                        "loc": snap["devices"]["location"],
                    });
                    use std::io::Write;
                    if let Ok(mut fh) = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(format!("{}/history.jsonl", sh.state_dir))
                    {
                        let _ = writeln!(fh, "{line}");
                    }
                    let mut h = sh.history.lock().unwrap();
                    h.push(line);
                    let cut = h.len().saturating_sub(1440);
                    if cut > 0 {
                        h.drain(0..cut);
                    }
                }
                if t - last_timeline >= 30 {
                    last_timeline = t;
                    model::timeline(&sh, 24);
                }
                if t - last_activity >= 60 {
                    last_activity = t;
                    // job load for the minute, measured only once:
                    // it goes both into the file log AND into Postgres
                    let sample = cpu.sample();
                    let mut top = 0.0f64;
                    let mut user = 0.0f64;
                    let mut top_unit = String::new();
                    if let Some(m) = sample.as_object() {
                        for (k, v) in m {
                            let cores = v.as_f64().unwrap_or(0.0);
                            if k.starts_with("user:") {
                                user += cores;
                            } else if cores > top {
                                top = cores;
                                top_unit = k.trim_end_matches(".service").to_string();
                            }
                        }
                    }
                    let mut enriched = snap.clone();
                    if let Some(o) = enriched.as_object_mut() {
                        o.insert(
                            "_cpu".into(),
                            serde_json::json!({"user": user, "top": top, "top_unit": top_unit, "detail": sample}),
                        );
                    }
                    model::log_activity(&sh, &enriched, &sample);
                    if t - last_pg >= 60 {
                        last_pg = t;
                        if let Err(e) = store::insert_sample(&enriched) {
                            eprintln!("[presence] postgres (sample) : {e}");
                        }
                    }
                    if t - last_forecast_pg >= 300 {
                        last_forecast_pg = t;
                        if let Err(e) = store::insert_forecast(&enriched) {
                            eprintln!("[presence] postgres (forecast) : {e}");
                        }
                    }
                    // sante de la base, pour la page et le diagnostic
                    if let Ok(mut h) = sh.pg_health.lock() {
                        *h = store::health();
                    }
                }
                std::thread::sleep(Duration::from_secs_f64(tick));
            }
        });
    }

    let app = Router::new()
        .route("/", get(page))
        .route("/index.html", get(page))
        .route("/api/state", get(api_state))
        .route("/api/forecast", get(api_forecast))
        .route("/api/history", get(api_history))
        .route("/api/timeline", get(api_timeline))
        // Automatic task runs: ingestion open to schedulers
        // (Hermes cron, systemd timer, home-grown script) and read access for the UI.
        .route("/api/automation/runs", post(automation_ingest).get(api_automation))
        .route("/api/automation", get(api_automation))
        .route("/healthz", get(|| async { "ok\n" }))
        .with_state(sh.clone());

    println!(
        "[presence] http://{host}:{port}  state={state_dir}  pid={}  build=rust {}",
        std::process::id(),
        now_iso()
    );
    let listener = tokio::net::TcpListener::bind(format!("{host}:{port}"))
        .await
        .expect("bind");
    axum::serve(listener, app).await.expect("serve");
}

async fn page(State(sh): State<Arc<Shared>>) -> impl IntoResponse {
    let html = sh.cached.read().unwrap().html.clone();
    if html.is_empty() {
        return (StatusCode::SERVICE_UNAVAILABLE, Html("<p>démarrage…</p>".to_string()));
    }
    (StatusCode::OK, Html(html))
}

async fn api_state(State(sh): State<Arc<Shared>>) -> impl IntoResponse {
    let body = sh.cached.read().unwrap().body.clone();
    if body.is_empty() {
        return (StatusCode::SERVICE_UNAVAILABLE, [("content-type", "application/json")], "{}".to_string());
    }
    (StatusCode::OK, [("content-type", "application/json; charset=utf-8")], body)
}

async fn api_forecast(State(sh): State<Arc<Shared>>) -> impl IntoResponse {
    let fc = sh.forecast.lock().unwrap().clone();
    (
        StatusCode::OK,
        [("content-type", "application/json; charset=utf-8")],
        fc.to_string(),
    )
}

async fn api_timeline(State(sh): State<Arc<Shared>>) -> impl IntoResponse {
    // Le ticker rafraichit ce corps toutes les 30 s : aucune requete SQL dans
    // le runtime tokio (un client Postgres bloquant y panique).
    let body = sh.timeline_body.lock().map(|b| b.clone()).unwrap_or_default();
    if body.is_empty() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            [("content-type", "application/json; charset=utf-8")],
            "{\"pts\":[],\"stats\":{}}".to_string(),
        );
    }
    (
        StatusCode::OK,
        [("content-type", "application/json; charset=utf-8")],
        body,
    )
}

/// Announcement of an automatic run. A run never touches presence: it is
/// logged separately, with its relevance verdict.
async fn automation_ingest(
    State(sh): State<Arc<Shared>>,
    Json(body): Json<Value>,
) -> impl IntoResponse {
    let run = automation::ingest(&sh.state_dir, &body);
    let ok = run["ok"].as_bool().unwrap_or(true);
    let code = if ok { StatusCode::OK } else { StatusCode::BAD_REQUEST };
    (
        code,
        [("content-type", "application/json; charset=utf-8")],
        run.to_string(),
    )
}

async fn api_automation(State(sh): State<Arc<Shared>>) -> impl IntoResponse {
    let body = automation::summary(&sh.state_dir, 24).to_string();
    (
        StatusCode::OK,
        [("content-type", "application/json; charset=utf-8")],
        body,
    )
}

async fn api_history(State(sh): State<Arc<Shared>>) -> impl IntoResponse {
    let h = sh.history.lock().unwrap().clone();
    (
        StatusCode::OK,
        [("content-type", "application/json; charset=utf-8")],
        Value::Array(h).to_string(),
    )
}
