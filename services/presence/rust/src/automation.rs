//! Automatic task runs: ingestion, relevance verdict, summary.
//!
//! Founding rule: **an automatic run is never a presence signal**. A cron
//! that writes a `role='user'` message must not make marc present. These
//! runs therefore live in their own file (`automation.jsonl`), the presence
//! computation does not read them, and they only serve to answer one
//! question: did this job run at the right time, and what for?
//!
//! Ingestion is generic: any scheduler (Hermes cron, systemd timer,
//! home-grown script) can announce a run through
//! `POST /api/automation/runs`. Nothing here depends on marc's infra.
//!

use serde_json::{json, Value};
use std::io::Write;

use crate::util::{now, read};

/// True when marc is not in front of any device.
pub fn is_absent(state: &str) -> bool {
    state.starts_with("away_")
}

/// Relevance verdict. Computed at ingestion, never guessed after the fact:
/// `exit` and the presence state at startup are the only inputs.
pub fn verdict(
    state_at_start: &str,
    needs_absence: bool,
    class: &str,
    exit: Option<i64>,
) -> &'static str {
    if matches!(exit, Some(code) if code != 0) {
        // A failure stays a failure, even at the right time: the
        // time slot does not explain it.
        return "a_revoir";
    }
    if is_absent(state_at_start) {
        if needs_absence || class == "heavy" {
            "pertinent"
        } else {
            // Nothing to gain from running during an absence: the window was
            // merely useless, not harmful.
            "sans_objet"
        }
    } else if needs_absence || class == "heavy" {
        // It took CPU while marc was there: that is exactly what
        // these jobs must avoid.
        "a_revoir"
    } else {
        "sans_objet"
    }
}

fn path(state_dir: &str) -> String {
    format!("{state_dir}/automation.jsonl")
}

/// Appends a run to the log (one JSON line per run, append only).
pub fn append(state_dir: &str, run: &Value) {
    if let Ok(mut fh) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path(state_dir))
    {
        let _ = writeln!(fh, "{run}");
    }
}

/// Re-reads the log, from most recent to oldest, capped at `max` runs.
pub fn load(state_dir: &str, max: usize) -> Vec<Value> {
    let Some(txt) = read(&path(state_dir)) else {
        return Vec::new();
    };
    // A log that grows without bound is a design bug, not a
    // feature: we keep only the last lines in memory.
    let mut out: Vec<Value> = txt
        .lines()
        .rev()
        .take(max)
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .collect();
    out.reverse();
    out
}

/// Records a run announced by a scheduler.
///
/// Expected fields: `job` (required), then `kind`, `class` (heavy|light),
/// `needs_absence`, `started`, `ended`, `exit`, `presence`, `device`, `note`.
pub fn ingest(state_dir: &str, body: &Value) -> Value {
    let job = body
        .get("job")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if job.is_empty() {
        return json!({"ok": false, "error": "champ 'job' requis"});
    }
    let class = body.get("class").and_then(|v| v.as_str()).unwrap_or("heavy");
    let needs_absence = body
        .get("needs_absence")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let state_at_start = body
        .get("presence")
        .and_then(|v| v.as_str())
        .unwrap_or("inconnu");
    let exit = body.get("exit").and_then(|v| v.as_i64());
    let started = body.get("started").and_then(|v| v.as_i64()).unwrap_or_else(now);
    let run = json!({
        "job": job,
        "kind": body.get("kind").and_then(|v| v.as_str()).unwrap_or("cron"),
        "class": class,
        "needs_absence": needs_absence,
        "started": started,
        "ended": body.get("ended").and_then(|v| v.as_i64()),
        "exit": exit,
        "presence_at_start": state_at_start,
        "verdict": verdict(state_at_start, needs_absence, class, exit),
        "device": body.get("device").cloned().unwrap_or(Value::Null),
        "note": body.get("note").and_then(|v| v.as_str()).unwrap_or(""),
    });
    append(state_dir, &run);
    run
}

/// Summary for display: counters over the window, and the list of runs
/// that started during an absence (this is the explicit request: show
/// what ran while marc was not there).
pub fn summary(state_dir: &str, hours: i64) -> Value {
    let t = now();
    let since = t - hours * 3600;
    let runs = load(state_dir, 500);
    let (mut ok, mut revoir, mut sans) = (0u32, 0u32, 0u32);
    let mut during_absence: Vec<Value> = Vec::new();
    let mut last: Option<Value> = None;
    for r in runs.iter().rev() {
        let started = r.get("started").and_then(|v| v.as_i64()).unwrap_or(0);
        if started < since {
            break;
        }
        if last.is_none() {
            last = Some(r.clone());
        }
        match r.get("verdict").and_then(|v| v.as_str()).unwrap_or("") {
            "pertinent" => ok += 1,
            "a_revoir" => revoir += 1,
            _ => sans += 1,
        }
        let state = r.get("presence_at_start").and_then(|v| v.as_str()).unwrap_or("");
        if is_absent(state) && during_absence.len() < 40 {
            during_absence.push(r.clone());
        }
    }
    json!({
        "window_h": hours,
        "counts": {"pertinent": ok, "a_revoir": revoir, "sans_objet": sans},
        "total": ok + revoir + sans,
        "last": last.unwrap_or(Value::Null),
        "during_absence": during_absence,
        "note": "un run automatique n'est jamais un signal de presence",
    })
}
