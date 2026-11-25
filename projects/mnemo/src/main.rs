//! mnemo: the retention engine.
//!
//! It reads Marc's Hermes conversations, scores them on the axes the podcast
//! queue already uses (matiere, points, ignorance, importance, focus), extracts
//! the points he did not understand, and writes an explanation sheet that is at
//! once a page on his site, a source for the podcast pipeline and a typing
//! drill on typer.marcpartensky.com.
//!
//! Two ways to score: `score` is deterministic and free (no model call at all,
//! the ranking of a whole month in seconds), `scan` uses the model to read what
//! a keyword count cannot see and to write the sheets.

mod analyze;
mod config;
mod http;
mod llm;
mod model;
mod publish;
mod scan;
mod score_det;
mod sessions;
mod store;

pub type R<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

use clap::{Parser, Subcommand};
use config::Config;
use http::App;
use llm::Llm;
use std::io::Read;
use std::path::Path;
use std::sync::Arc;
use store::Store;

#[derive(Parser)]
#[command(
    name = "mnemo",
    version,
    about = "Score Marc's conversations, explain what he missed, feed the podcast and the typing drill"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// HTTP server: the JSON API, the site and the MCP endpoint.
    Serve,
    /// Read new conversations, score them, write the briefs.
    Scan {
        #[arg(long, default_value_t = 0.0)]
        since: f64,
        #[arg(long, default_value_t = 20)]
        limit: usize,
        /// Skip the brief writing, score only.
        #[arg(long, default_value_t = false)]
        no_briefs: bool,
        /// Also enqueue the briefs in the podcast pipeline.
        #[arg(long, default_value_t = false)]
        publish: bool,
    },
    /// Rank every conversation of a window with NO model call at all.
    Score {
        /// Window in days (30 = the last month).
        #[arg(long, default_value_t = 30)]
        days: i64,
        /// Only this many conversations, oldest first (0 = the whole window).
        #[arg(long, default_value_t = 0)]
        limit: usize,
        /// Rescore the conversations a model already scored.
        #[arg(long, default_value_t = false)]
        force: bool,
        /// Score and report, write nothing.
        #[arg(long, default_value_t = false)]
        dry: bool,
        /// Priority floor of the ranking printed at the end.
        #[arg(long, default_value_t = 0.0)]
        min_priority: f64,
    },
    /// The scored conversations, most important first.
    Backlog {
        #[arg(long, default_value_t = 0.0)]
        min_priority: f64,
        #[arg(long, default_value_t = 30)]
        limit: i64,
    },
    /// Print the explanation sheet of one conversation.
    Brief { id: String },
    /// Regenerate the typing drill from every brief written so far.
    Wordlist,
    /// Send one conversation to a channel: podcast or typer.
    Publish {
        id: String,
        #[arg(long, default_value = "podcast")]
        to: String,
    },
    /// List the raw conversations the engine can see.
    Sessions {
        #[arg(long, default_value_t = 0.0)]
        since: f64,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    /// How the deterministic score is computed.
    ScoreSystem,
}

fn ensure_token(path: &Path) -> R<String> {
    if let Ok(existing) = std::fs::read_to_string(path) {
        let token = existing.trim().to_string();
        if !token.is_empty() {
            return Ok(token);
        }
    }
    let mut bytes = [0u8; 24];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(path, &token)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(token)
}

fn now_epoch() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

async fn build(cfg: &Config) -> R<App> {
    let store = Store::open(cfg.db.as_deref()).await?;
    store.migrate().await?;
    let token = ensure_token(&cfg.token_file)?;
    Ok(App {
        cfg: cfg.clone(),
        llm: Llm::new(cfg),
        store,
        token,
    })
}

#[tokio::main]
async fn main() -> R<()> {
    let cli = Cli::parse();
    let cfg = Config::from_env();

    match cli.cmd {
        Cmd::Serve => {
            let app = Arc::new(build(&cfg).await?);
            let listener =
                tokio::net::TcpListener::bind(format!("{}:{}", cfg.bind, cfg.port)).await?;
            println!(
                "[mnemo] listening on http://{}:{} (model {}, db {})",
                cfg.bind,
                cfg.port,
                cfg.llm_model,
                cfg.db.as_deref().unwrap_or("none (dry run)")
            );
            if cfg.open {
                println!("[mnemo] MNEMO_OPEN=1: the API is not gated, the proxy must be");
            }
            axum::serve(listener, http::router(app)).await?;
        }
        Cmd::Scan {
            since,
            limit,
            no_briefs,
            publish,
        } => {
            let app = build(&cfg).await?;
            let report = scan::run(&app, since, limit, !no_briefs, publish).await?;
            println!("{}", serde_json::to_string_pretty(&report)?);
        }
        Cmd::Score {
            days,
            limit,
            force,
            dry,
            min_priority,
        } => {
            let app = build(&cfg).await?;
            let since = now_epoch() - days as f64 * 86400.0;
            // A reading that cost a model call is never replaced by a keyword
            // count unless the caller insists.
            let skip: std::collections::HashSet<String> = if force {
                Default::default()
            } else {
                app.store.model_scored_ids().await?.into_iter().collect()
            };
            let metas = sessions::metas(&cfg, since, 0, 0)?;
            let seen = metas.len();
            let (mut scored, mut skipped) = (0usize, 0usize);
            // The report is built here rather than read back from the database,
            // so the pass can be run and checked without a database at all.
            let mut top: Vec<serde_json::Value> = Vec::new();
            // Distribution by priority floor: how many conversations would the
            // briefing pipeline actually pick up.
            let mut buckets = [0usize; 7];
            let mut focused = 0usize;
            for (i, meta) in metas.iter().enumerate() {
                if limit > 0 && i >= limit {
                    break;
                }
                if skip.contains(&meta.id) {
                    skipped += 1;
                    continue;
                }
                let text = sessions::his_words(&cfg, &meta.id)?;
                if text.trim().is_empty() {
                    skipped += 1;
                    continue;
                }
                let score = score_det::score(meta, &text);
                if score.focus {
                    focused += 1;
                }
                buckets[if score.priorite >= 16.0 {
                    0
                } else if score.priorite >= 14.0 {
                    1
                } else if score.priorite >= 12.0 {
                    2
                } else if score.priorite >= 10.0 {
                    3
                } else if score.priorite >= 8.0 {
                    4
                } else if score.priorite >= 6.0 {
                    5
                } else {
                    6
                }] += 1;
                if score.priorite >= min_priority {
                    top.push(serde_json::json!({
                        "priorite": score.priorite,
                        "matiere": score.matiere,
                        "points": score.points,
                        "ignorance": score.ignorance,
                        "importance": score.importance,
                        "focus": score.focus,
                        "source": score.source,
                        "started_at": score.started_at,
                        "sujet": score.sujet,
                        "points_liste": score.points_liste,
                        "id": score.id,
                    }));
                }
                if !dry {
                    app.store.put_score(&score).await?;
                }
                scored += 1;
            }
            top.sort_by(|a, b| {
                b["priorite"]
                    .as_f64()
                    .partial_cmp(&a["priorite"].as_f64())
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            top.truncate(20);
            // What the site will actually serve, read back from the database.
            let served = app.store.ranked(since, min_priority, 5).await.unwrap_or_default();
            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "model": "det",
                    "ai_calls": 0,
                    "window_days": days,
                    "seen": seen,
                    "scored": scored,
                    "skipped": skipped,
                    "dry": dry,
                    "focus": focused,
                    "distribution": {
                        ">=16": buckets[0],
                        "14-16": buckets[1],
                        "12-14": buckets[2],
                        "10-12": buckets[3],
                        "8-10": buckets[4],
                        "6-8": buckets[5],
                        "<6": buckets[6],
                    },
                    "served": served,
                    "top": top,
                }))?
            );
        }
        Cmd::Backlog {
            min_priority,
            limit,
        } => {
            let app = build(&cfg).await?;
            let items = app.store.backlog(min_priority, limit).await?;
            println!("{}", serde_json::to_string_pretty(&items)?);
        }
        Cmd::Brief { id } => {
            let app = build(&cfg).await?;
            match app.store.brief(&id).await? {
                Some(brief) => {
                    println!("# {}", brief["title"].as_str().unwrap_or_default());
                    println!("\n{}\n", brief["summary"].as_str().unwrap_or_default());
                    println!("{}", brief["body"].as_str().unwrap_or_default());
                    let gaps = app.store.gaps(&id).await?;
                    if !gaps.is_empty() {
                        println!("\n--- points non compris ---");
                        for gap in gaps {
                            println!("- {}", gap["point"].as_str().unwrap_or_default());
                        }
                    }
                }
                None => eprintln!("[mnemo] no brief for {id}"),
            }
        }
        Cmd::Wordlist => {
            let app = build(&cfg).await?;
            let terms: Vec<String> = app
                .store
                .terms()
                .await?
                .into_iter()
                .map(|(term, _)| term)
                .collect();
            if terms.is_empty() {
                eprintln!("[mnemo] no brief written yet, nothing to drill");
            } else {
                println!("{}", publish::to_typer(&cfg, &terms)?);
            }
        }
        Cmd::Publish { id, to } => {
            let app = build(&cfg).await?;
            match to.as_str() {
                "typer" => {
                    let terms: Vec<String> = app
                        .store
                        .terms()
                        .await?
                        .into_iter()
                        .map(|(term, _)| term)
                        .collect();
                    println!("{}", publish::to_typer(&cfg, &terms)?);
                }
                "podcast" => {
                    let session = sessions::load_one(&cfg, &id)?
                        .ok_or_else(|| format!("unknown session: {id}"))?;
                    let mut scored = analyze::analyze(
                        &app.llm,
                        std::slice::from_ref(&session),
                        cfg.analyze_tokens,
                    )
                    .await?;
                    let score = scored.remove(0);
                    app.store.put_score(&score).await?;
                    let brief =
                        analyze::write_brief(&app.llm, &score, &session, cfg.brief_tokens).await?;
                    app.store.put_brief(&brief).await?;
                    let reference = publish::to_podcast(&cfg, &score, Some(&brief)).await?;
                    app.store.mark_published(&id, "podcast", &reference).await?;
                    println!("{reference}");
                }
                other => return Err(format!("unknown channel: {other}").into()),
            }
        }
        Cmd::Sessions { since, limit } => {
            let list = sessions::load(&cfg, since, limit)?;
            for session in list {
                println!(
                    "{}  {:>6} words  {}",
                    session.id,
                    session.words,
                    if session.title.is_empty() {
                        session.user_text.chars().take(60).collect::<String>()
                    } else {
                        session.title.clone()
                    }
                );
            }
        }
        Cmd::ScoreSystem => {
            println!("{}", serde_json::to_string_pretty(&score_det::explain())?);
        }
    }
    Ok(())
}
