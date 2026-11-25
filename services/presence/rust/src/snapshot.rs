//! Building the JSON snapshot (same contract as the old Python dashboard).
use serde_json::{json, Map, Value};
use std::sync::Arc;

use crate::model::{self};
use crate::probes;
use crate::state::{Device, Shared};
use crate::util::{env_s, local_tm, now, now_f, read};

pub struct Ctx {
    pub sh: Arc<Shared>,
    pub windows: model::Windows,
    pub overrides: std::collections::HashMap<String, String>,
    pub model: Option<model::Model>,
    pub model_at: i64,
    pub hermes_home: String,
    pub hint_fresh: i64,
    /// Channels/devices/automation sources: nothing marc-specific hard-coded here.
    pub conf: crate::conf::Conf,
}

fn dev_json(d: &Device) -> Value {
    Value::Object(d.map.clone())
}

/// Hermes activity: USER messages only, cron/oneshot/subagent excluded.
pub fn hermes_activity(hermes_home: &str, conf: &crate::conf::Conf) -> Value {
    let db = format!("{hermes_home}/.hermes/state.db");
    // Two safeguards, not one:
    //  - allow-list of INTERACTIVE channels (comes from presence.json);
    //  - explicit exclusion of automation sources, and of child sessions
    //    (parent_session_id), so that a cron writing a user message
    //    never makes marc present.
    let sources = conf.interactive_sources_sql();
    let auto = conf.automation_sources_sql();
    let q = format!(
        "select s.source, count(*), sum(case when m.timestamp > strftime('%s','now')-900 then 1 else 0 end), \
         max(m.timestamp) from messages m join sessions s on s.id=m.session_id \
         where s.archived=0 and m.role='user' and s.source in ({sources}) \
         and s.source not in ({auto}) and s.parent_session_id is null \
         and m.timestamp > strftime('%s','now')-3600 group by s.source order by 4 desc"
    );
    // IN-PROCESS read: `sqlite3` started from the sandboxed service
    // failed (spawn refused) and the page displayed 0 messages without any error.
    let mut channels: Vec<Value> = Vec::new();
    let (mut n15, mut n60, mut last_at, mut last_src): (i64, i64, Option<f64>, String) =
        (0, 0, None, String::new());
    let mut ok = false;
    let mut error = Value::Null;
    match crate::model::db_rows(&db, &q) {
        Ok(rows) => {
            ok = true;
            for (src, n, m15, at) in rows {
                n60 += n;
                n15 += m15;
                if last_at.is_none() {
                    last_at = Some(at);
                    last_src = src.clone();
                }
                channels.push(json!({"source": src, "at": at, "n": n}));
            }
        }
        Err(e) => error = Value::from(e),
    }
    json!({
        "ok": ok,
        "error": error,
        "sessions_15m": if n15 > 0 { 1 } else { 0 },
        "messages_15m": n15,
        "messages_60m": n60,
        "channels": channels,
        "last_message_at": last_at,
        "last_user_at": last_at,
        "last_user_source": if last_src.is_empty() { Value::Null } else { Value::from(last_src) },
    })
}

pub fn gateway(hermes_home: &str) -> Value {
    let path = format!("{hermes_home}/.hermes/gateway_state.json");
    let Some(raw) = read(&path) else { return json!({"ok": false}) };
    let Ok(v) = serde_json::from_str::<Value>(&raw) else { return json!({"ok": false}) };
    let mut plats = Map::new();
    if let Some(p) = v["platforms"].as_object() {
        for (k, val) in p {
            plats.insert(
                k.clone(),
                json!({
                    "state": val["state"],
                    "updated_at": val["updated_at"],
                    "detail": val["listener_base"],
                }),
            );
        }
    }
    json!({
        "ok": true,
        "state": v["gateway_state"],
        "active_agents": v["active_agents"],
        "updated_at": v["updated_at"],
        "profiles": v["served_profiles"],
        "platforms": plats,
    })
}

fn loadavg_mem() -> Value {
    let load1: f64 = read("/proc/loadavg")
        .and_then(|s| s.split_whitespace().next().map(|x| x.to_string()))
        .and_then(|x| x.parse().ok())
        .unwrap_or(0.0);
    let mut mem: Map<String, Value> = Map::new();
    if let Some(txt) = read("/proc/meminfo") {
        for line in txt.lines() {
            if let Some((k, v)) = line.split_once(':') {
                if let Some(kb) = v.trim().split_whitespace().next().and_then(|x| x.parse::<u64>().ok()) {
                    mem.insert(k.to_string(), Value::from(kb / 1024));
                }
            }
        }
    }
    let g = |k: &str| mem.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
    json!({
        "load1": (load1 * 100.0).round() / 100.0,
        "mem_total_mb": g("MemTotal"),
        "mem_avail_mb": g("MemAvailable"),
        "swap_used_mb": g("SwapTotal").saturating_sub(g("SwapFree")),
    })
}

/// home / work / out / out? / unknown, from the most reliable signal to the least reliable.
fn where_am_i(tower_active: bool, mac: &Device, phone: &Device, phone_net: &Map<String, Value>) -> (String, String) {
    if tower_active {
        return ("home".into(), "tower in use".into());
    }
    let mac_loc = if mac.b("online") { mac.s("location") } else { String::new() };
    if mac_loc == "home" || mac_loc == "work" {
        return (
            mac_loc.clone(),
            format!("Mac on {mac_loc} network ({})", mac.s("gw_mac")),
        );
    }
    let hw = phone_net.get("home_wifi").and_then(|v| v.as_bool());
    if hw == Some(true) {
        return ("home".into(), "phone on home wifi".into());
    }
    if mac_loc == "out" && hw == Some(false) {
        return ("out".into(), "Mac and phone off the home network".into());
    }
    if hw == Some(false) {
        let addr = phone_net.get("ts_addr").and_then(|v| v.as_str()).unwrap_or("?");
        return (
            "out?".into(),
            format!("phone off home wifi ({addr}), Mac silent"),
        );
    }
    if mac_loc == "out" {
        return ("out".into(), "Mac off the home network".into());
    }
    let _ = phone;
    ("unknown".into(), "no location signal".into())
}

/// Full snapshot + writing of devices.json and forecast.json.
pub fn build(ctx: &mut Ctx) -> Value {
    let t = now();
    let t_f = now_f();
    if t - ctx.model_at > 300 {
        ctx.model = Some(model::build_model(std::path::Path::new(&ctx.hermes_home)));
        ctx.model_at = t;
        ctx.overrides = model::load_overrides();
    }
    probes::sample_kasm(&ctx.sh);
    let cidle = probes::console_idle();

    let mac = ctx.sh.mac.lock().unwrap().clone();
    let phone = ctx.sh.phone.lock().unwrap().clone();
    let kasm = ctx.sh.kasm.lock().unwrap().clone();
    let mut net = ctx.sh.net.lock().unwrap().clone();
    for (k, v) in phone.map.clone() {
        if k.starts_with("ts_") || k == "home_wifi" {
            net.insert(k, v);
        }
    }
    let active_thr = env_s("PRESENCE_CONSOLE_ACTIVE_IDLE", "600").parse().unwrap_or(600.0);
    let tower_active = kasm.active || cidle.map(|i| i < active_thr).unwrap_or(false);
    let tower_why = if kasm.active {
        "Kasm desktop in use".to_string()
    } else if cidle.map(|i| i < active_thr).unwrap_or(false) {
        format!("tower console used (idle {:.0} s)", cidle.unwrap_or(0.0))
    } else {
        "tower idle".to_string()
    };
    let tower_state = if tower_active {
        "active"
    } else if kasm.clients > 0 {
        "desktop connected"
    } else {
        "inactive"
    };
    let mut tower: Value = json!({
        "online": true,
        "active": tower_active,
        "state": tower_state,
        "why": tower_why,
        "kasm_clients": kasm.clients,
        "kasm_peers": kasm.peers,
        "kasm_tx_bps": kasm.tx_bps,
        "console_idle_s": cidle.map(|i| i.round() as i64),
        "checked_at": t,
    });
    if let Some(o) = tower.as_object_mut() {
        for (k, v) in loadavg_mem().as_object().cloned().unwrap_or_default() {
            o.insert(k, v);
        }
    }
    let (location, location_why) = where_am_i(tower_active, &mac, &phone, &net);

    let mut active_device: Option<String> = None;
    for (name, on) in [
        ("tower", tower_active),
        ("mac", mac.is_active()),
        ("phone", phone.is_active()),
    ] {
        if on {
            active_device = Some(name.to_string());
            break;
        }
    }
    {
        let mut la = ctx.sh.last_active.lock().unwrap();
        if let Some(d) = &active_device {
            la.insert(d.clone(), t);
            la.insert("any".into(), t);
        }
    }
    if active_device.is_some() {
        ctx.sh.save_last_active();
    }
    let last_active: Map<String, Value> = ctx
        .sh
        .last_active
        .lock()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.clone(), Value::from(*v)))
        .collect();

    let why_active = match active_device.as_deref() {
        Some("tower") => tower_why.clone(),
        Some("mac") => mac.s("why"),
        Some("phone") => phone.s("why"),
        _ => "no active device".to_string(),
    };
    let devices = json!({
        "mac": dev_json(&mac),
        "phone": dev_json(&phone),
        "tower": tower,
        "active_device": active_device,
        "why": why_active,
        "location": location,
        "location_why": location_why,
        "last_active": last_active,
        "at": t,
    });

    // Hermes activity + fresh hint (only if it is fresh: a 02:00
    // message must not stick a "on the Mac" presence all night long)
    let act = hermes_activity(&ctx.hermes_home, &ctx.conf);
    let mut active_device = active_device;
    let mut why_active = why_active;
    let mut hint = Value::Null;
    if let (Some(at), Some(src)) = (
        act["last_user_at"].as_f64(),
        act["last_user_source"].as_str(),
    ) {
        let age = (t_f - at).max(0.0);
        // The channel -> device mapping comes from presence.json: that is what
        // lets the same binary serve another infra.
        let dev = ctx.conf.device_for(src);
        if let Some(d) = dev.clone() {
            if age < ctx.hint_fresh as f64 {
                hint = json!({"device": d, "age_s": age.round() as i64, "source": src});
                if active_device.is_none() {
                    active_device = Some(d.to_string());
                    why_active = format!("Hermes message ({src}) {} min ago", (age / 60.0) as i64);
                }
            }
        }
    }
    let mut devices = devices;
    devices["active_device"] = if let Some(d) = &active_device { Value::from(d.clone()) } else { Value::Null };
    devices["why"] = Value::from(why_active.clone());
    if !hint.is_null() {
        devices["hint"] = hint.clone();
    }

    let connected_why = {
        let age = act["last_user_at"].as_f64().map(|a| t_f - a).unwrap_or(1e9);
        if age < 15.0 * 60.0 {
            format!(
                "user message {} min ago ({})",
                (age / 60.0) as i64,
                act["last_user_source"].as_str().unwrap_or("?")
            )
        } else {
            String::new()
        }
    };
    let phone_off = probes::phone_off_for(&phone);
    let mac_quiet = !mac.b("online") || mac.b("lid_closed") || !mac.b("display_on");
    let v = model::verdict(
        &ctx.windows,
        &ctx.overrides,
        t,
        active_device.as_deref(),
        &why_active,
        &location,
        &location_why,
        &phone.s("state"),
        phone_off,
        mac_quiet,
        &connected_why,
    );
    let (kind, until) = model::window_at(&ctx.windows, &ctx.overrides, t);
    let forecast = match &ctx.model {
        Some(m) => {
            // typical week: P(present) per day x hour, for the heat map.
            // Rows are MONDAY-first because the page labels them lun..dim,
            // while the model indexes slots by tm_wday (0 = Sunday).
            let mut heat: Vec<Vec<f64>> = Vec::with_capacity(7);
            for d in 0..7i64 {
                let wday = (d + 1) % 7;
                let mut row = Vec::with_capacity(24);
                for h in 0..24i64 {
                    row.push((m.p(wday * 96 + h * 4) * 1000.0).round() / 1000.0);
                }
                heat.push(row);
            }
            if let Ok(mut g) = ctx.sh.heat.lock() {
                *g = json!(heat);
            }
            model::forecast(&ctx.sh, m, devices.as_object().unwrap(), &v.state)
        }
        None => json!({}),
    };
    *ctx.sh.forecast.lock().unwrap() = forecast.clone();

    let tm = local_tm(t);
    let presence = json!({
        "state": v.state,
        "why": v.why,
        "window": kind,
        "until": until,
        "absent_confident": v.absent_confident,
        "location": v.location,
        "location_why": v.location_why,
        "windows": model::transitions(&ctx.windows, &ctx.overrides, t, 6),
        "overrides": ctx.overrides,
        "tz": std::env::var("TZ").unwrap_or_else(|_| "America/New_York".into()),
        "local": format!("{:02}:{:02}", tm.tm_hour, tm.tm_min),
        "error": Value::Null,
    });

    let mut snap = json!({
        "at": model::iso_local(t),
        "epoch": t,
        "host": ctx.sh.host,
        "presence": presence,
        "tower": {
            "marc_cpu_pct": 0.0,
            "marc_cpu_smooth": 0.0,
            "kasm": kasm.clients > 0,
            "busy": tower_active,
            "local_model": false,
            "ttys": [],
            "tty_why": Value::Null,
            "note": "cpu/ttys removed: useless and costly measurements",
        },
        "devices": devices,
        "hermes": {
            "connected": !connected_why.is_empty(),
            "why": connected_why,
            "webui_post": false,
            "hint": hint,
        },
        "gateway": gateway(&ctx.hermes_home),
        "forecast": forecast,
        // Automatic runs: separated from presence by construction, and
        // displayed only when they started during an absence.
        "automation": crate::automation::summary(&ctx.sh.state_dir, 24),
        "config": ctx.conf.to_json(),
        "pid": std::process::id(),
    });

    // the rich "tower" block (kasm, console) replaces the summary: a single object
    if let Some(t) = tower.as_object_mut() {
        for (k, v) in loadavg_mem().as_object().cloned().unwrap_or_default() {
            t.insert(k, v);
        }
        t.insert("marc_cpu_pct".into(), Value::from(0.0));
        t.insert("marc_cpu_smooth".into(), Value::from(0.0));
        t.insert("local_model".into(), Value::Bool(false));
        t.insert("ttys".into(), Value::Array(vec![]));
        t.insert("tty_why".into(), Value::Null);
        t.insert("kasm".into(), Value::Bool(kasm.clients > 0));
        t.insert("busy".into(), Value::Bool(tower_active));
        t.insert(
            "note".into(),
            Value::from("cpu/ttys removed: useless and costly measurements"),
        );
    }
    if let Some(o) = snap.as_object_mut() {
        o.insert("tower".into(), tower.clone());
        if let Some(h) = o.get_mut("hermes").and_then(|t| t.as_object_mut()) {
            for (k, v) in act.as_object().cloned().unwrap_or_default() {
                h.insert(k, v);
            }
        }
    }

    // persistence (historical contract)
    crate::util::write_atomic(
        &format!("{}/devices.json", ctx.sh.state_dir),
        &snap["devices"].to_string(),
    );
    crate::util::write_atomic(
        &format!("{}/forecast.json", ctx.sh.state_dir),
        &snap["forecast"].to_string(),
    );
    snap
}
