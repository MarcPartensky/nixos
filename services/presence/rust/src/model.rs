//! Declared windows, presence verdict, forecast and activity log.
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::state::Shared;
use crate::util::{capture, env_s, local_tm, now, now_f, read, write_atomic, ymd};

pub const INTERACTIVE: [&str; 3] = ["at_tower", "at_mac", "at_phone"];

/// "2026-11-20T22:41:03-05:00" in local time (no timezone dependency).
pub fn iso_local(t: i64) -> String {
    let tm = local_tm(t);
    let off = tm.tm_gmtoff;
    let sign = if off < 0 { '-' } else { '+' };
    let o = off.abs();
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}{}{:02}:{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        sign,
        o / 3600,
        (o % 3600) / 60
    )
}

pub fn is_interactive(state: &str) -> bool {
    INTERACTIVE.contains(&state)
}

// ---------------------------------------------------------------- config

#[derive(Clone)]
pub struct Windows {
    pub sleep_start: (u32, u32),
    pub sleep_end: (u32, u32),
    pub work_days: Vec<i64>,
    pub work_start: (u32, u32),
    pub work_end: (u32, u32),
}

fn hm(v: &str, def: (u32, u32)) -> (u32, u32) {
    let mut it = v.split(':');
    let h = it.next().and_then(|x| x.parse().ok());
    let m = it.next().and_then(|x| x.parse().ok());
    match (h, m) {
        (Some(h), Some(m)) => (h, m),
        _ => def,
    }
}

pub fn load_windows() -> Windows {
    let mut w = Windows {
        sleep_start: (2, 30),
        sleep_end: (8, 30),
        work_days: vec![1, 2, 3, 4, 5],
        work_start: (9, 0),
        work_end: (18, 30),
    };
    let path = env_s("TASKQ_PRESENCE_CONFIG", "/etc/taskq/presence.json");
    let Some(raw) = read(&path) else { return w };
    let Ok(v) = serde_json::from_str::<Value>(&raw) else { return w };
    if let Some(s) = v["sleep"].as_object() {
        if let Some(x) = s.get("start").and_then(|x| x.as_str()) {
            w.sleep_start = hm(x, w.sleep_start);
        }
        if let Some(x) = s.get("end").and_then(|x| x.as_str()) {
            w.sleep_end = hm(x, w.sleep_end);
        }
    }
    if let Some(s) = v["work"].as_object() {
        if let Some(days) = s.get("days").and_then(|x| x.as_array()) {
            w.work_days = days.iter().filter_map(|d| d.as_i64()).collect();
        }
        if let Some(x) = s.get("start").and_then(|x| x.as_str()) {
            w.work_start = hm(x, w.work_start);
        }
        if let Some(x) = s.get("end").and_then(|x| x.as_str()) {
            w.work_end = hm(x, w.work_end);
        }
    }
    w
}

/// Per-date overrides (day off / remote work) read from the taskq database.
/// One query every 5 min, never per HTTP request.
pub fn load_overrides() -> HashMap<String, String> {
    let mut out = HashMap::new();
    let Some(txt) = capture(
        "psql",
        &[
            "postgresql://taskq@127.0.0.1/taskq",
            "-tA",
            "-q",
            "-c",
            "select value from state where key='presence_overrides'",
        ],
        8,
    ) else {
        return out;
    };
    let txt = txt.trim();
    if txt.is_empty() {
        return out;
    }
    if let Ok(v) = serde_json::from_str::<Value>(txt) {
        if let Some(m) = v.as_object() {
            for (k, val) in m {
                if let Some(kind) = val.get("kind").and_then(|x| x.as_str()) {
                    out.insert(k.clone(), kind.to_string());
                }
            }
        }
    }
    out
}

/// (kind, end epoch) of the active window, or (None, None).
pub fn window_at(w: &Windows, ov: &HashMap<String, String>, t: i64) -> (Option<String>, Option<i64>) {
    let tm = local_tm(t);
    let today = ymd(t);
    let day_start = t - (tm.tm_hour as i64 * 3600 + tm.tm_min as i64 * 60 + tm.tm_sec as i64);
    let at = |h: (u32, u32)| day_start + h.0 as i64 * 3600 + h.1 as i64 * 60;
    let sleep_s = at(w.sleep_start);
    let sleep_e = at(w.sleep_end);
    let work_s = at(w.work_start);
    let work_e = at(w.work_end);
    let wday = tm.tm_wday as i64;
    // a window started yesterday can run today (sleep)
    for back in [1i64, 0] {
        let off = if back == 1 { -86400 } else { 0 };
        let s = sleep_s + off;
        let e = sleep_e + off;
        if s <= t && t < e {
            return (Some("sleep".into()), Some(e));
        }
        if back == 0 && w.work_days.contains(&wday) && !ov.contains_key(&today) {
            if work_s <= t && t < work_e {
                return (Some("work".into()), Some(work_e));
            }
        }
    }
    (None, None)
}

/// Next window boundaries (for the page).
pub fn transitions(w: &Windows, ov: &HashMap<String, String>, t: i64, count: usize) -> Vec<Value> {
    let mut out: Vec<(i64, String)> = Vec::new();
    for ahead in -1i64..8 {
        let day_t = t + ahead * 86400;
        let tm = local_tm(day_t);
        let day_start = day_t - (tm.tm_hour as i64 * 3600 + tm.tm_min as i64 * 60 + tm.tm_sec as i64);
        let at = |h: (u32, u32)| day_start + h.0 as i64 * 3600 + h.1 as i64 * 60;
        let mut add = |s: i64, e: i64, kind: &str| {
            let (tn, te) = match kind {
                "sleep" => ("début sommeil", "fin sommeil"),
                _ => ("début travail", "fin travail"),
            };
            for (x, label) in [(s, tn.to_string()), (e, te.to_string())] {
                if x > t {
                    out.push((x, label));
                }
            }
        };
        add(at(w.sleep_start), at(w.sleep_end), "sleep");
        let day = ymd(day_t);
        if w.work_days.contains(&(tm.tm_wday as i64)) && !ov.contains_key(&day) {
            add(at(w.work_start), at(w.work_end), "work");
        }
    }
    out.sort_by_key(|x| x.0);
    out.truncate(count);
    out.into_iter()
        .map(|(x, label)| serde_json::json!({"at": iso_local(x), "epoch": x, "label": label}))
        .collect()
}

// ---------------------------------------------------------------- verdict

pub struct Verdict {
    pub state: String,
    pub why: String,
    pub absent_confident: bool,
    pub location: String,
    pub location_why: String,
}

/// Verdict based on the devices, then on the location, then on the habits.
#[allow(clippy::too_many_arguments)]
pub fn verdict(
    w: &Windows,
    ov: &HashMap<String, String>,
    t: i64,
    active_device: Option<&str>,
    why_active: &str,
    location: &str,
    location_why: &str,
    phone_state: &str,
    phone_off_for: i64,
    mac_quiet: bool,
    connected_why: &str,
) -> Verdict {
    let (kind, _) = window_at(w, ov, t);
    let kind = kind.unwrap_or_default();
    let base = |state: &str, why: String, absent: bool| Verdict {
        state: state.to_string(),
        why,
        absent_confident: absent,
        location: location.to_string(),
        location_why: location_why.to_string(),
    };
    match active_device {
        Some("tower") => return base("at_tower", why_active.to_string(), false),
        Some(d @ ("mac" | "phone")) => {
            return base(&format!("at_{d}"), why_active.to_string(), true)
        }
        _ => {}
    }
    if location == "work" {
        return base("away_work", location_why.to_string(), true);
    }
    if location == "out" {
        return base("away_out", location_why.to_string(), true);
    }
    let tm = local_tm(t);
    let night = !(11..23).contains(&tm.tm_hour);
    let at_home_or_unknown = location.is_empty() || location == "home" || location == "unknown";
    if night && phone_off_for >= 20 * 60 && mac_quiet && at_home_or_unknown {
        return base(
            "away_sleep",
            format!("nuit, téléphone éteint depuis {} min, Mac au repos", phone_off_for / 60),
            true,
        );
    }
    if kind == "sleep" {
        let _ = phone_state;
        return base("away_sleep", "fenetre sommeil, aucun appareil actif".into(), true);
    }
    if kind == "work" && location != "home" {
        let mut why = "fenetre travail, aucun appareil actif".to_string();
        if !connected_why.is_empty() {
            why.push_str(&format!(" (derniere interaction : {connected_why})"));
        }
        return base("away_work", why, true);
    }
    if location == "out?" {
        return base("away_out", location_why.to_string(), true);
    }
    base(
        "home_idle",
        if location == "home" {
            "à la maison, aucun appareil actif".to_string()
        } else if connected_why.is_empty() {
            "aucun appareil actif".to_string()
        } else {
            connected_why.to_string()
        },
        false,
    )
}

/// The `needs_absence` gate of the taskq queue.
pub fn may_start(state: &str, absent_confident: bool, connected: bool) -> (bool, String) {
    match state {
        "at_tower" => (false, "marc utilise tower".into()),
        "at_mac" => (true, "marc est sur mac, tower libre".into()),
        "at_phone" => (true, "marc est sur telephone, tower libre".into()),
        "away_out" | "away_work" | "away_sleep" if absent_confident => {
            (true, format!("marc absent ({state})"))
        }
        _ => {
            if absent_confident {
                (true, "marc absent (fenetre)".into())
            } else if !connected {
                (true, "marc absent (aucune interaction recente)".into())
            } else {
                (false, "marc actif (interaction recente)".into())
            }
        }
    }
}

// ---------------------------------------------------------------- forecast

pub const SLOT_MIN: i64 = 15;
const SLOTS_DAY: i64 = 24 * 60 / SLOT_MIN;
const SLOTS_WEEK: i64 = 7 * SLOTS_DAY;
const HALF_LIFE_DAYS: f64 = 21.0;

pub fn slot_of(t: i64) -> i64 {
    let tm = local_tm(t);
    (tm.tm_wday as i64 * 1440 + tm.tm_hour as i64 * 60 + tm.tm_min as i64) / SLOT_MIN
}

/// `tm_wday` is 0 = Sunday, so the working week is 1..=5.
/// Getting this wrong splits the priors as (Sun..Thu, Fri..Sat) instead of
/// (Mon..Fri, Sat..Sun).
pub fn is_weekday(wday: i64) -> bool {
    (1..=5).contains(&wday)
}

#[derive(Default)]
pub struct Model {
    pub week: Vec<[f64; 2]>,
    pub day: Vec<[f64; 2]>, // 2 * 96: working day / weekend
    pub samples: u64,
}

impl Model {
    pub fn p(&self, slot: i64) -> f64 {
        let slot = slot.rem_euclid(SLOTS_WEEK);
        let [a, tot] = self
            .week
            .get(slot as usize)
            .copied()
            .unwrap_or([0.0, 0.0]);
        let d = (slot % SLOTS_DAY) as usize;
        let [da, dtot] = self
            .day
            .get(d * 2 + if is_weekday(slot / SLOTS_DAY) { 0 } else { 1 })
            .copied()
            .unwrap_or([0.0, 0.0]);
        let prior = (da + 1.0) / (dtot + 2.0);
        let k = 10.0;
        (a + k * prior) / (tot + k)
    }
}

fn state_dir() -> PathBuf {
    PathBuf::from(env_s("PRESENCE_STATE_DIR", "/var/lib/hermes/presence-dashboard"))
}

/// Labelled minutes: Hermes user messages, Mac screen, activity
/// log, old history.jsonl (after the cleanup date).

/// Aggregation query per channel (source, total, 15 min, last message).
/// IN-PROCESS read: see `db_messages` (the sqlite3 CLI failed under
/// systemd).
pub fn db_rows(db: &str, query: &str) -> Result<Vec<(String, i64, i64, f64)>, String> {
    let con = rusqlite::Connection::open_with_flags(
        db,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| format!("{db}: {e}"))?;
    let _ = con.busy_timeout(std::time::Duration::from_secs(5));
    let mut stmt = con.prepare(query).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, f64>(3)?,
            ))
        })
        .map_err(|e| e.to_string())?;
    Ok(rows.flatten().collect())
}

/// Timestamps of the Hermes USER messages (interactive sources only).
/// Opens state.db read-only with a busy timeout: the agent writes into
/// that database continuously.
pub fn db_messages(hermes_home: &Path) -> Result<Vec<i64>, String> {
    let db = hermes_home.join(".hermes/state.db");
    let con = rusqlite::Connection::open_with_flags(
        &db,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| format!("{}: {e}", db.display()))?;
    let _ = con.busy_timeout(std::time::Duration::from_secs(5));
    let sources = "'desktop','matrix','local','cli','tui','api_server','discord','telegram','signal','whatsapp'";
    let q = format!(
        "select cast(m.timestamp as integer) from messages m join sessions s on s.id=m.session_id \
         where m.role='user' and s.source in ({sources})"
    );
    let mut stmt = con.prepare(&q).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |r| r.get::<_, i64>(0))
        .map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for r in rows.flatten() {
        out.push(r);
    }
    Ok(out)
}

fn labelled(hermes_home: &Path) -> HashMap<i64, bool> {
    let mut lab: HashMap<i64, bool> = HashMap::new();
    // history.jsonl written before 2026-11-20 23:00 EST is polluted (presence
    // "stuck" after a night-time message): we do not learn from it.
    let clean_since: i64 = env_s("PRESENCE_CLEAN_SINCE", "1795234800").parse().unwrap_or(0);
    // IN-PROCESS read (rusqlite): the `sqlite3` binary failed under the
    // systemd sandbox (spawn refused), which emptied the model silently.
    match db_messages(hermes_home) {
        Ok(timestamps) => {
            for ts in timestamps {
                let m = ts / 60;
                for k in (m - 5)..=(m + 5) {
                    lab.insert(k, true);
                }
            }
        }
        Err(e) => eprintln!("[presence] state.db illisible : {e} (le modele perd les messages)"),
    }
    // Mac screen on (pmset intervals)
    if let Some(raw) = read(&state_dir().join("mac_display.json").to_string_lossy()) {
        if let Ok(v) = serde_json::from_str::<Value>(&raw) {
            if let Some(evs) = v["events"].as_array() {
                let mut on: Option<i64> = None;
                for e in evs {
                    let Some(t) = e.get(0).and_then(|x| x.as_i64()) else { continue };
                    let kind = e.get(1).and_then(|x| x.as_str()).unwrap_or("");
                    if kind == "on" {
                        on = on.or(Some(t));
                    } else if let Some(s) = on.take() {
                        if t - s < 16 * 3600 {
                            for m in (s / 60)..=(t / 60) {
                                lab.insert(m, true);
                            }
                        }
                    }
                }
            }
        }
    }
    for name in ["history.jsonl", "activity.jsonl"] {
        let path = state_dir().join(name);
        let Ok(fh) = std::fs::File::open(&path) else { continue };
        use std::io::BufRead;
        for line in std::io::BufReader::new(fh).lines().map_while(Result::ok) {
            let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
            let Some(t) = v["t"].as_i64() else { continue };
            if t < clean_since {
                continue;
            }
            let m = t / 60;
            let active = v["state"].as_str().map(is_interactive).unwrap_or(false);
            if active {
                lab.insert(m, true);
            } else {
                lab.entry(m).or_insert(false);
            }
        }
    }
    // gaps = absent (inside the covered period)
    if let Some(first) = lab.keys().min().copied() {
        let last = now() / 60;
        for m in first..last {
            lab.entry(m).or_insert(false);
        }
    }
    lab
}

pub fn build_model(hermes_home: &Path) -> Model {
    let lab = labelled(hermes_home);
    let mut m = Model {
        week: vec![[0.0, 0.0]; SLOTS_WEEK as usize],
        day: vec![[0.0, 0.0]; SLOTS_DAY as usize * 2],
        samples: 0,
    };
    let lam = std::f64::consts::LN_2 / (HALF_LIFE_DAYS * 86400.0);
    let n = now();
    for (minute, act) in &lab {
        let t = minute * 60;
        let w = (-lam * (n - t).max(0) as f64).exp();
        let slot = slot_of(t);
        let a = if *act { w } else { 0.0 };
        m.week[slot as usize][0] += a;
        m.week[slot as usize][1] += w;
        let d = (slot % SLOTS_DAY) as usize;
        let idx = d * 2 + if is_weekday(slot / SLOTS_DAY) { 0 } else { 1 };
        m.day[idx][0] += a;
        m.day[idx][1] += w;
        m.samples += 1;
    }
    eprintln!("[presence] modele : {} minutes etiquetees", m.samples);
    m
}

/// Next calm periods of at least `min_minutes`.
pub fn best_windows(m: &Model, t: i64, min_minutes: i64, count: usize, threshold: f64) -> Vec<Value> {
    let mut out = Vec::new();
    let cur = slot_of(t);
    let base = t / (SLOT_MIN * 60) * SLOT_MIN * 60;
    let mut start: Option<i64> = None;
    let mut sum = 0.0;
    let mut n = 0;
    for i in 1..(2 * SOLTS_MAX) {
        let p = m.p(cur + i);
        if p < threshold {
            if start.is_none() {
                start = Some(i);
                sum = 0.0;
                n = 0;
            }
            sum += p;
            n += 1;
        }
        let last = i == SOLTS_MAX - 1;
        if (p >= threshold || last) && start.is_some() {
            let s = start.take().unwrap();
            let length = (i - s) * SLOT_MIN;
            if length >= min_minutes && n > 0 {
                out.push(serde_json::json!({
                    "start": base + s * SLOT_MIN * 60,
                    "minutes": length,
                    "p_mean": (sum / n as f64 * 1000.0).round() / 1000.0,
                }));
            }
            if out.len() >= count {
                break;
            }
        }
    }
    out
}

const SOLTS_MAX: i64 = 2 * 24 * 60 / SLOT_MIN;

/// Forecast: present now, or soon (habit + triggers).
pub fn forecast(sh: &Shared, model: &Model, snap_devices: &Map<String, Value>, state: &str) -> Value {
    let t = now();
    let cur = slot_of(t);
    let steps = 30 / SLOT_MIN + 1;
    let p_next = (0..steps).map(|i| model.p(cur + i)).fold(0.0f64, f64::max);
    let p_now = model.p(cur);
    let location = snap_devices.get("location").and_then(|v| v.as_str()).unwrap_or("");
    let mut triggers: Vec<String> = Vec::new();
    let prev = sh.forecast.lock().unwrap().clone();
    let prev_loc = prev["location"].as_str().unwrap_or("");
    if ["out", "out?", "work"].contains(&prev_loc) && location == "home" {
        triggers.push("retour à la maison détecté".into());
    }
    let phone = snap_devices.get("phone").and_then(|v| v.as_object());
    if let Some(p) = phone {
        if p.get("state").and_then(|v| v.as_str()) == Some("verrouille") && !is_interactive(state) {
            triggers.push("téléphone allumé (écran verrouillé)".into());
        }
    }
    if let Some(m) = snap_devices.get("mac").and_then(|v| v.as_object()) {
        let on = m.get("online").and_then(|v| v.as_bool()).unwrap_or(false);
        let display = m.get("display_on").and_then(|v| v.as_bool()).unwrap_or(false);
        let active = m.get("active").and_then(|v| v.as_bool()).unwrap_or(false);
        let idle = m.get("idle_s").and_then(|v| v.as_f64()).unwrap_or(1e9);
        if on && display && !active && idle < 600.0 {
            triggers.push("Mac allumé, utilisé il y a moins de 10 min".into());
        }
    }
    if let Some(last) = snap_devices
        .get("last_active")
        .and_then(|v| v.as_object())
        .and_then(|m| m.get("any"))
        .and_then(|v| v.as_i64())
    {
        if t - last < 20 * 60 && !is_interactive(state) {
            triggers.push(format!("actif il y a {} min", (t - last) / 60));
        }
    }
    let present = is_interactive(state);
    let sticky = prev["reserve_until"].as_i64().unwrap_or(0) > t;
    let threshold: f64 = env_s("PRESENCE_RESERVE_P", "0.45").parse().unwrap_or(0.45);
    let mut reserve = present || !triggers.is_empty() || p_next >= threshold || sticky;
    if (state == "away_out" || state == "away_work") && triggers.is_empty() {
        reserve = present; // outside: the hourly habit is not enough
    }
    let why = if present {
        "présent maintenant".to_string()
    } else if !triggers.is_empty() {
        triggers.join("; ")
    } else if p_next >= threshold {
        format!("habitude : P(présent < 30 min) = {:.0}%", p_next * 100.0)
    } else if sticky {
        "réservation maintenue (hystérésis)".to_string()
    } else {
        format!("calme prévu (P = {:.0}%)", p_next * 100.0)
    };
    let reserve_until = if reserve {
        t + 20 * 60
    } else {
        prev["reserve_until"].as_i64().unwrap_or(0)
    };
    // Learned weekday/weekend contrast over the waking window (08:00-24:00):
    // the per-day-type prior is what lets a Saturday inherit from the previous
    // Saturdays AND Sundays, so a weekend that is busier than the working week
    // shows up even after few samples. Nights are left out: they dilute the
    // contrast that matters during the day.
    let mut wd_sum = 0.0;
    let mut we_sum = 0.0;
    for d in 0..7i64 {
        for h in 8..24i64 {
            let p = model.p(d * SLOTS_DAY + h * 4);
            if is_weekday(d) {
                wd_sum += p;
            } else {
                we_sum += p;
            }
        }
    }
    let wd_mean = wd_sum / (5.0 * 16.0);
    let we_mean = we_sum / (2.0 * 16.0);
    let daytype = if is_weekday(slot_of(t) / SLOTS_DAY) {
        "weekday"
    } else {
        "weekend"
    };
    let mut fc = serde_json::json!({
        "at": t,
        "state": state,
        "location": location,
        "daytype": daytype,
        "p_now": (p_now * 1000.0).round() / 1000.0,
        "p_next_30": (p_next * 1000.0).round() / 1000.0,
        "reserve": reserve,
        "reserve_until": reserve_until,
        "why": why,
        "triggers": triggers,
        "samples": model.samples,
        "habit": {
            "weekday": (wd_mean * 1000.0).round() / 1000.0,
            "weekend": (we_mean * 1000.0).round() / 1000.0,
            "weekend_ratio": ((we_mean / wd_mean.max(0.001)) * 100.0).round() / 100.0,
        },
        "best_windows": best_windows(model, t, 60, 4, 0.2),
    });
    let curve: Vec<Value> = (0..SLOTS_DAY)
        .map(|i| {
            let slot_t = (t / (SLOT_MIN * 60) + i) * SLOT_MIN * 60;
            serde_json::json!({
                "t": slot_t,
                "p": (model.p(cur + i) * 1000.0).round() / 1000.0,
            })
        })
        .collect();
    *sh.curve.lock().unwrap() = curve.clone();
    fc["curve"] = Value::Array(curve.into_iter().take(48).collect());
    fc
}

// ---------------------------------------------------------------- journal

/// CPU (cores) consumed by user.slice and by system unit since the last
/// sample. cgroup file reads only: no fork.
#[derive(Default)]
pub struct CpuSampler {
    prev: HashMap<String, u64>,
    at: f64,
}

impl CpuSampler {
    fn usage(path: &str) -> Option<u64> {
        let txt = read(&format!("{path}/cpu.stat"))?;
        for line in txt.lines() {
            if let Some(v) = line.strip_prefix("usage_usec ") {
                return v.trim().parse().ok();
            }
        }
        None
    }

    pub fn sample(&mut self) -> Value {
        let t = now_f();
        let mut cur: HashMap<String, u64> = HashMap::new();
        for (name, path) in [
            ("user:marc", "/sys/fs/cgroup/user.slice/user-1000.slice"),
            ("user:hermes", "/sys/fs/cgroup/user.slice/user-988.slice"),
        ] {
            if let Some(u) = Self::usage(path) {
                cur.insert(name.into(), u);
            }
        }
        if let Ok(entries) = std::fs::read_dir("/sys/fs/cgroup/system.slice") {
            for e in entries.flatten() {
                let name = e.file_name().to_string_lossy().to_string();
                if name.ends_with(".service") || name.ends_with(".scope") {
                    if let Some(u) = Self::usage(&e.path().to_string_lossy()) {
                        cur.insert(name, u);
                    }
                }
            }
        }
        let mut out = Map::new();
        if self.at > 0.0 {
            let dt_us = (t - self.at).max(1.0) * 1e6;
            for (k, v) in &cur {
                if let Some(old) = self.prev.get(k) {
                    if v >= old {
                        let cores = (v - old) as f64 / dt_us;
                        if cores >= 0.02 || k.starts_with("user:") {
                            out.insert(k.clone(), Value::from((cores * 100.0).round() / 100.0));
                        }
                    }
                }
            }
        }
        self.prev = cur;
        self.at = t;
        Value::Object(out)
    }
}

/// One line per minute: presence, device, location, CPU of background tasks.
pub fn log_activity(sh: &Shared, snap: &Value, sample: &Value) {
    let line = serde_json::json!({
        "t": now(),
        "state": snap["presence"]["state"],
        "device": snap["devices"]["active_device"],
        "loc": snap["devices"]["location"],
        "mac": snap["devices"]["mac"]["state"],
        "phone": snap["devices"]["phone"]["state"],
        "home_wifi": snap["devices"]["phone"]["home_wifi"],
        "hermes_msg_15m": snap["hermes"]["messages_15m"],
        "reserve": snap["forecast"]["reserve"],
        "cpu": sample,
    });
    let path = format!("{}/activity.jsonl", sh.state_dir);
    use std::io::Write;
    if let Ok(mut fh) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(fh, "{line}");
    }
    if let Ok(meta) = std::fs::metadata(&path) {
        if meta.len() > 40_000_000 {
            // compaction: we keep the last 200,000 lines
            if let Some(txt) = read(&path) {
                let keep: Vec<&str> = txt.lines().rev().take(200_000).collect();
                let joined: Vec<&str> = keep.into_iter().rev().collect();
                write_atomic(&path, &(joined.join("\n") + "\n"));
            }
        }
    }
}

// ---------------------------------------------------------------- timeline

/// Compact series of the last `hours` hours, for the page graph.
///
/// Format deliberately byte-frugal (24 h = 1440 points): lists of
/// values + dictionaries, instead of repeated objects.
pub fn timeline(sh: &Shared, hours: i64) -> String {
    let now_t = now();
    if let Ok(g) = sh.timeline.lock() {
        if let Some((at, body)) = g.as_ref() {
            if now_t - *at < 15 {
                return body.clone();
            }
        }
    }
    let from = now_t - hours * 3600;
    type Cell = (String, String, String, bool, f64, f64, String);
    let mut pts: std::collections::BTreeMap<i64, Cell> = std::collections::BTreeMap::new();
    // Source of truth: Postgres (one row per minute). If the database is
    // unreachable, we fall back to the file logs: the graph must
    // never disappear just because the database is ailing.
    let mut pg_ok = false;
    match crate::store::samples_since(hours) {
        Ok(rows) => {
            pg_ok = true;
            for r in rows {
                pts.insert(
                    r.t / 60,
                    (
                        r.state.unwrap_or_default(),
                        r.device.unwrap_or_default(),
                        r.loc.unwrap_or_default(),
                        r.reserve.unwrap_or(false),
                        r.cpu_user.map(|v| v as f64).unwrap_or(-1.0),
                        r.cpu_top.map(|v| v as f64).unwrap_or(-1.0),
                        r.top_unit.unwrap_or_default(),
                    ),
                );
            }
        }
        Err(e) => eprintln!("[presence] postgres (timeline) : {e}"),
    }
    // 1. fallback : rich log (activity.jsonl) then history (history.jsonl)
    let read_lines = |name: &str| -> Vec<Value> {
        let mut out = Vec::new();
        if let Some(txt) = read(&format!("{}/{name}", sh.state_dir)) {
            for line in txt.lines() {
                if let Ok(v) = serde_json::from_str::<Value>(line) {
                    out.push(v);
                }
            }
        }
        out
    };
    if !pg_ok {
    for v in read_lines("history.jsonl") {
        let Some(t) = v["t"].as_i64() else { continue };
        if t < from {
            continue;
        }
        let e = pts.entry(t / 60).or_insert_with(|| {
            (String::new(), String::new(), String::new(), false, -1.0, -1.0, String::new())
        });
        e.0 = v["state"].as_str().unwrap_or("").to_string();
        e.1 = v["device"].as_str().unwrap_or("").to_string();
        e.2 = v["loc"].as_str().unwrap_or("").to_string();
    }
    for v in read_lines("activity.jsonl") {
        let Some(t) = v["t"].as_i64() else { continue };
        if t < from {
            continue;
        }
        let mut user = 0.0;
        let mut top = -1.0;
        let mut topname = String::new();
        if let Some(cpu) = v["cpu"].as_object() {
            for (k, val) in cpu {
                let cores = val.as_f64().unwrap_or(0.0);
                if k.starts_with("user:") {
                    user += cores;
                } else if cores > top {
                    top = cores;
                    topname = k.trim_end_matches(".service").trim_end_matches(".scope").to_string();
                }
            }
        }
        let e = pts.entry(t / 60).or_insert_with(|| {
            (String::new(), String::new(), String::new(), false, -1.0, -1.0, String::new())
        });
        if e.0.is_empty() {
            e.0 = v["state"].as_str().unwrap_or("").to_string();
            e.1 = v["device"].as_str().unwrap_or("").to_string();
            e.2 = v["loc"].as_str().unwrap_or("").to_string();
        }
        e.3 = v["reserve"].as_bool().unwrap_or(false);
        e.4 = user;
        e.5 = top;
        e.6 = topname;
    }
    } // fin du repli fichier
    // 2. label dictionaries
    let mut states: Vec<String> = Vec::new();
    let mut devices: Vec<String> = Vec::new();
    let mut locs: Vec<String> = Vec::new();
    let idx = |list: &mut Vec<String>, v: &str| -> i64 {
        if v.is_empty() {
            return -1;
        }
        match list.iter().position(|x| x == v) {
            Some(i) => i as i64,
            None => {
                list.push(v.to_string());
                (list.len() - 1) as i64
            }
        }
    };
    let mut rows: Vec<Value> = Vec::with_capacity(pts.len());
    let mut present_min = 0i64;
    let mut cpu_present = 0.0;
    let mut cpu_absent = 0.0;
    let mut cpu_absent_n = 0i64;
    for (minute, (state, device, loc, reserve, user, top, topname)) in &pts {
        let si = idx(&mut states, state);
        let di = idx(&mut devices, device);
        let li = idx(&mut locs, loc);
        let present = is_interactive(state);
        if present {
            present_min += 1;
        }
        if *user >= 0.0 {
            if present {
                cpu_present += user + top.max(0.0);
            } else {
                cpu_absent += user + top.max(0.0);
                cpu_absent_n += 1;
            }
        }
        rows.push(serde_json::json!([
            minute * 60,
            si,
            di,
            li,
            if *reserve { 1 } else { 0 },
            if *user >= 0.0 { Value::from((user * 100.0).round() / 100.0) } else { Value::Null },
            if *top >= 0.0 { Value::from((top * 100.0).round() / 100.0) } else { Value::Null },
            topname
        ]));
    }
    let forecast: Vec<Value> = sh
        .curve
        .lock()
        .map(|c| c.clone())
        .unwrap_or_default()
        .into_iter()
        .map(|v| serde_json::json!([v["t"], v["p"]]))
        .collect();
    let fc = sh.forecast.lock().unwrap().clone();
    let out = serde_json::json!({
        "now": now_t,
        "hours": hours,
        "states": states,
        "devices": devices,
        "locs": locs,
        "pts": rows,
        "forecast": forecast,
        "calm": fc["best_windows"].clone(),
        "heat": sh.heat.lock().map(|h| h.clone()).unwrap_or(Value::Null),
        "habit": fc["habit"].clone(),
        "daytype": fc["daytype"].clone(),
        "reserve": fc["reserve"].clone(),
        "stats": {
            "present_minutes": present_min,
            "points": pts.len(),
            "cpu_present_avg": if present_min > 0 { (cpu_present / present_min as f64 * 100.0).round() / 100.0 } else { 0.0 },
            "cpu_absent_avg": if cpu_absent_n > 0 { (cpu_absent / cpu_absent_n as f64 * 100.0).round() / 100.0 } else { 0.0 },
        },
    })
    .to_string();
    if let Ok(mut g) = sh.timeline.lock() {
        *g = Some((now_t, out.clone()));
    }
    if let Ok(mut body) = sh.timeline_body.lock() {
        *body = out.clone();
    }
    out
}
