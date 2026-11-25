//! Probes: Mac (SSH), phone (SSH), tailscale, tower signals.
use serde_json::{Map, Value};
use std::time::Duration;

use crate::state::{place_label, Device, Kasm, Shared};
use crate::util::{env_f, env_s, kv, now, now_f, run, run_timeout};

fn ssh_opts(state_dir: &str, persist: bool, timeout_s: u64) -> Vec<String> {
    let mut v: Vec<String> = vec![
        "-o".into(),
        "BatchMode=yes".into(),
        "-o".into(),
        "StrictHostKeyChecking=accept-new".into(),
        "-o".into(),
        format!("ConnectTimeout={timeout_s}"),
        "-o".into(),
        "ServerAliveInterval=0".into(),
    ];
    if persist {
        // a master keeps the session up: the probe costs ~50 ms instead of 300
        v.extend(
            [
                "-o",
                "ControlMaster=auto",
                "-o",
                "ControlPersist=120",
                "-o",
                &format!("ControlPath={state_dir}/ssh/%h-%p-%r"),
            ]
            .iter()
            .map(|s| s.to_string()),
        );
    } else {
        v.extend(["-o", "ControlMaster=no"].iter().map(|s| s.to_string()));
    }
    v
}

pub fn ssh(state_dir: &str, host: &str, cmd: &str, persist: bool, timeout_s: u64) -> (i32, String) {
    let _ = std::fs::create_dir_all(format!("{state_dir}/ssh"));
    let mut args = ssh_opts(state_dir, persist, timeout_s);
    args.push(host.to_string());
    args.push(cmd.to_string());
    run_timeout("ssh", &args, Duration::from_secs(timeout_s + 3))
}

fn ssh_close(state_dir: &str, host: &str) {
    let args = vec![
        "-O".to_string(),
        "exit".to_string(),
        "-o".to_string(),
        format!("ControlPath={state_dir}/ssh/%h-%p-%r"),
        host.to_string(),
    ];
    let _ = run_timeout("ssh", &args, Duration::from_secs(5));
}

pub const MAC_CMD: &str = concat!(
    "ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print \"hidle_ns=\" $NF; exit}'; ",
    "pmset -g assertions 2>/dev/null | grep -q 'Prevent sleep while display is on' ",
    "&& echo display=on || echo display=off; ",
    "echo console_user=$(stat -f %Su /dev/console 2>/dev/null); ",
    "gw=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}'); echo gw=$gw; ",
    "echo gw_mac=$(arp -n $gw 2>/dev/null | awk '{print $4}'); ",
    "echo lid=$(ioreg -r -k AppleClamshellState | awk '/AppleClamshellState/{print $NF; exit}'); ",
    "echo power=$(pmset -g batt | head -1 | grep -q AC && echo ac || echo batt)"
);

pub const PHONE_CMD: &str = concat!(
    "G=/system/bin/getprop; ",
    "echo screen_state=$($G debug.tracing.screen_state); ",
    "echo device_state=$($G debug.tracing.device_state); ",
    "echo battery=$($G debug.tracing.battery_status); ",
    "echo plug=$($G debug.tracing.plug_type)"
);

/// Mac probe: keyboard/mouse idle, screen, lid, network gateway.
pub fn probe_mac(sh: &Shared) {
    let mac_host = env_s("PRESENCE_MAC_HOST", "maclan");
    let fallback = env_s("PRESENCE_MAC_FALLBACK", "mac");
    let active_idle = env_f("PRESENCE_MAC_ACTIVE_IDLE", 120.0);
    let home_gws: Vec<String> = env_s("PRESENCE_HOME_GW", "74:37:5f:a1:dd:70")
        .split(',')
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect();
    let mut hosts = vec![mac_host.clone()];
    if !fallback.is_empty() && fallback != mac_host {
        hosts.push(fallback);
    }
    let mut res: Option<(String, std::collections::HashMap<String, String>)> = None;
    let mut used = hosts[0].clone();
    for host in &hosts {
        let (code, out) = ssh(&sh.state_dir, host, MAC_CMD, true, 4);
        used = host.clone();
        let fields = kv(&out);
        if code == 0 && fields.contains_key("hidle_ns") {
            res = Some((host.clone(), fields));
            break;
        }
    }
    let mut dev = sh.mac.lock().unwrap();
    let Some((host, f)) = res else {
        ssh_close(&sh.state_dir, &used);
        dev.set_offline(&format!("ssh {used} injoignable"));
        dev.map.insert("host".into(), Value::from(used));
        return;
    };
    let idle = f
        .get("hidle_ns")
        .and_then(|v| v.parse::<f64>().ok())
        .map(|ns| ns / 1e9);
    let display = f.get("display").map(|v| v == "on").unwrap_or(false);
    let console = f.get("console_user").cloned().unwrap_or_default();
    let logged = console == "marc";
    let gw_mac = f.get("gw_mac").cloned().unwrap_or_default().to_lowercase();
    let lid = f.get("lid").cloned().unwrap_or_default() == "Yes";
    let mut location = if home_gws.contains(&gw_mac) {
        "home".to_string()
    } else if gw_mac.len() >= 11 && gw_mac.chars().all(|c| c.is_ascii_hexdigit() || c == ':') {
        place_label(&sh.state_dir, &gw_mac)
    } else {
        "unknown".to_string()
    };
    if location != "home" && host != mac_host && location == "unknown" {
        // reachable only through the tunnel: not on the home LAN
        location = "out".to_string();
    }
    let state = if idle.map(|i| logged && display && i < active_idle).unwrap_or(false) {
        "active"
    } else if lid {
        "capot fermé"
    } else if logged && !display {
        "veille écran"
    } else if logged && idle.map(|i| i >= active_idle).unwrap_or(false) {
        "inactif"
    } else if !logged {
        "verrouillé"
    } else {
        "inactif"
    };
    let why = if state == "active" {
        format!("Mac actif (idle {:.0} s)", idle.unwrap_or(0.0))
    } else {
        match idle {
            Some(i) => format!("Mac joignable, {state} (idle {i:.0} s)"),
            None => format!("Mac joignable, {state}"),
        }
    };
    dev.set(vec![
        ("online", Value::Bool(true)),
        ("active", Value::Bool(state == "active")),
        ("state", Value::from(state)),
        ("why", Value::from(why)),
        ("host", Value::from(host)),
        ("location", Value::from(location)),
        ("gw_mac", Value::from(if gw_mac.is_empty() { Value::Null } else { Value::from(gw_mac) })),
        ("lid_closed", Value::Bool(lid)),
        ("display_on", Value::Bool(display)),
        ("console_user", Value::from(console)),
        ("power", Value::from(f.get("power").cloned().unwrap_or_default())),
        (
            "idle_s",
            idle.map(|i| Value::from((i * 10.0).round() / 10.0)).unwrap_or(Value::Null),
        ),
    ]);
}

pub fn probe_phone(sh: &Shared) {
    let host = env_s("PRESENCE_PHONE_HOST", "phone");
    let (code, out) = ssh(&sh.state_dir, &host, PHONE_CMD, false, 6);
    let f = kv(&out);
    let mut dev = sh.phone.lock().unwrap();
    if code != 0 || !f.contains_key("screen_state") {
        dev.set_offline("téléphone injoignable");
        return;
    }
    let screen: i64 = f.get("screen_state").and_then(|v| v.parse().ok()).unwrap_or(-1);
    let dstate = f.get("device_state").cloned().unwrap_or_default();
    let unlocked = dstate.starts_with("0:");
    // `debug.tracing.screen_state` carries the Display.STATE_* enum that
    // DisplayPowerController writes (AOSP): 0 unknown, 1 OFF, 2 ON, 3 DOZE,
    // 4 DOZE_SUSPEND, 5 VR, 6 ON_SUSPEND. Reading 1 as "on" inverts the whole
    // night: a phone in deep sleep reports 1, so every night looked like
    // "at_phone" and `away_sleep` could never trigger.
    const DISPLAY_OFF: i64 = 1;
    const DISPLAY_ON: i64 = 2;
    const DISPLAY_DOZE: i64 = 3;
    const DISPLAY_DOZE_SUSPEND: i64 = 4;
    const DISPLAY_VR: i64 = 5;
    const DISPLAY_ON_SUSPEND: i64 = 6;
    let lit = matches!(screen, DISPLAY_ON | DISPLAY_VR | DISPLAY_ON_SUSPEND);
    let active = lit && unlocked;
    let state = if lit {
        if unlocked {
            "actif"
        } else {
            "verrouille"
        }
    } else if screen == DISPLAY_OFF {
        "écran éteint"
    } else if matches!(screen, DISPLAY_DOZE | DISPLAY_DOZE_SUSPEND) {
        "veille"
    } else {
        // unknown (-1, 0): never count as "off", it would fake a sleep
        "inconnu"
    };
    dev.set(vec![
        ("online", Value::Bool(true)),
        ("active", Value::Bool(active)),
        ("state", Value::from(state)),
        ("why", Value::from(if active { "Téléphone actif".to_string() } else { format!("Téléphone joignable, {state}") })),
        ("screen_state", Value::from(screen)),
        ("device_state", Value::from(dstate)),
        ("battery", Value::from(f.get("battery").cloned().unwrap_or_default())),
        (
            "charging",
            Value::Bool(f.get("plug").map(|p| p != "0" && !p.is_empty()).unwrap_or(false)),
        ),
    ]);
}

/// The phone as seen by tailscale: online, current public IP, home wifi?
pub fn probe_tailscale(sh: &Shared) {
    let name = env_s("PRESENCE_PHONE_TS", "Xiaomi 13T Pro");
    let lan = env_s("PRESENCE_HOME_LAN", "192.168.1.");
    let Some(raw) = crate::util::capture("tailscale", &["status", "--json"], 8) else {
        return;
    };
    let Ok(v) = serde_json::from_str::<Value>(&raw) else { return };
    let home_ips: Vec<String> = v["Self"]["Addrs"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str())
                .filter(|s| !s.starts_with('['))
                .map(|s| s.rsplit_once(':').map(|(h, _)| h.to_string()).unwrap_or_default())
                .collect()
        })
        .unwrap_or_default();
    let mut out = Map::new();
    if let Some(peers) = v["Peer"].as_object() {
        for peer in peers.values() {
            if peer["HostName"].as_str() != Some(name.as_str()) {
                continue;
            }
            let addr = peer["CurAddr"]
                .as_str()
                .unwrap_or("")
                .rsplit_once(':')
                .map(|(h, _)| h.to_string())
                .unwrap_or_default();
            out.insert("ts_online".into(), Value::Bool(peer["Online"].as_bool().unwrap_or(false)));
            out.insert(
                "ts_addr".into(),
                if addr.is_empty() { Value::Null } else { Value::from(addr.clone()) },
            );
            out.insert(
                "home_wifi".into(),
                Value::Bool(!addr.is_empty() && (home_ips.contains(&addr) || addr.starts_with(&lan))),
            );
        }
    }
    *sh.net.lock().unwrap() = out;
}

/// Connected KasmVNC clients and video throughput (bytes sent / s), smoothed.
pub fn sample_kasm(sh: &Shared) {
    let (code, out) = run("ss", &["-Hti", "state", "established", "sport = :8443"], 8);
    let mut peers: Vec<String> = Vec::new();
    let mut total: u64 = 0;
    let mut current = false;
    if code == 0 {
        for line in out.lines() {
            if line.starts_with(' ') || line.starts_with('\t') {
                if let Some(idx) = line.find("bytes_sent:") {
                    let rest: String = line[idx + 11..]
                        .chars()
                        .take_while(|c| c.is_ascii_digit())
                        .collect();
                    if let Ok(n) = rest.parse::<u64>() {
                        if current {
                            total += n;
                        }
                    }
                }
            } else {
                let fields: Vec<&str> = line.split_whitespace().collect();
                if fields.len() >= 4 {
                    peers.push(fields[3].to_string());
                    current = true;
                } else {
                    current = false;
                }
            }
        }
    }
    let mut k: std::sync::MutexGuard<Kasm> = sh.kasm.lock().unwrap();
    let t = now_f();
    if let Some((pt, ptotal)) = k.prev {
        let dt = (t - pt).max(0.1);
        let bps = total.saturating_sub(ptotal) as f64 / dt;
        k.ema = Some(match k.ema {
            Some(e) => 0.6 * e + 0.4 * bps,
            None => bps,
        });
    }
    k.prev = if peers.is_empty() { None } else { Some((t, total)) };
    if peers.is_empty() {
        k.ema = Some(0.0);
    }
    k.clients = peers.len();
    k.peers = peers.into_iter().take(4).collect();
    k.tx_bps = k.ema.map(|e| (e * 10.0).round() / 10.0);
    let threshold = env_f("PRESENCE_VNC_ACTIVE_BPS", 2000.0);
    k.active = k.clients > 0 && k.ema.unwrap_or(0.0) >= threshold;
}

/// Idle (s) of tower's physical console, without who(1) and without the multiplexer effect.
pub fn console_idle() -> Option<f64> {
    let n = now_f();
    let mut best: Option<f64> = None;
    for tty in ["/dev/tty1", "/dev/tty2", "/dev/tty3"] {
        let Ok(meta) = std::fs::metadata(tty) else { continue };
        use std::os::unix::fs::MetadataExt;
        let at = meta.atime() as f64 + meta.atime_nsec() as f64 / 1e9;
        let idle = n - at;
        if idle < 0.0 {
            continue;
        }
        best = Some(best.map(|b: f64| b.min(idle)).unwrap_or(idle));
    }
    best
}

pub fn phone_off_for(phone: &Device) -> i64 {
    let st = phone.s("state");
    if st == "écran éteint" || st == "veille" {
        let since = phone.map.get("since").and_then(|v| v.as_i64()).unwrap_or_else(now);
        (now() - since).max(0)
    } else {
        0
    }
}
