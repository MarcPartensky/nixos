//! State shared between the probes (threads) and the HTTP server.
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::sync::{Mutex, RwLock};

use crate::util::{now, read, write_atomic};

/// A device = a JSON object (same schema as devices.py, so that the taskq
/// queue and the old dashboard keep reading devices.json without changes).
#[derive(Clone, Default)]
pub struct Device {
    pub map: Map<String, Value>,
    last_state: Option<String>,
}

impl Device {
    pub fn with_initial(since: Option<i64>) -> Self {
        let mut d = Device::default();
        d.map.insert("online".into(), Value::Bool(false));
        d.map.insert("active".into(), Value::Bool(false));
        d.map.insert("state".into(), Value::String("inconnu".into()));
        d.map.insert("why".into(), Value::String(String::new()));
        d.map.insert("since".into(), Value::from(since.unwrap_or(now())));
        d
    }

    /// Updates the fields; `since` only moves when `state` changes.
    pub fn set(&mut self, pairs: Vec<(&str, Value)>) {
        let mut state = None;
        for (k, v) in pairs {
            if k == "state" {
                if let Value::String(s) = &v {
                    state = Some(s.clone());
                }
            }
            self.map.insert(k.to_string(), v);
        }
        if let Some(s) = state {
            if self.last_state.as_deref() != Some(s.as_str()) {
                self.last_state = Some(s);
                self.map.insert("since".into(), Value::from(now()));
            }
        }
        self.map.insert("checked_at".into(), Value::from(now()));
    }

    pub fn s(&self, k: &str) -> String {
        self.map.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string()
    }

    pub fn b(&self, k: &str) -> bool {
        self.map.get(k).and_then(|v| v.as_bool()).unwrap_or(false)
    }

    pub fn is_active(&self) -> bool {
        self.b("active")
    }

    pub fn set_offline(&mut self, why: &str) {
        self.set(vec![
            ("online", Value::Bool(false)),
            ("active", Value::Bool(false)),
            ("state", Value::String("hors ligne".into())),
            ("why", Value::String(why.to_string())),
        ]);
    }
}

/// Kasm state (clients + smoothed video throughput).
#[derive(Default, Clone)]
pub struct Kasm {
    pub clients: usize,
    pub peers: Vec<String>,
    pub tx_bps: Option<f64>,
    pub active: bool,
    pub prev: Option<(f64, u64)>,
    pub ema: Option<f64>,
}

#[derive(Default)]
pub struct Cached {
    pub body: String, // full JSON, serialized once per tick
    pub html: String, // page with window.__SNAP__ already injected
}

pub struct Shared {
    pub state_dir: String,
    pub mac: Mutex<Device>,
    pub phone: Mutex<Device>,
    pub net: Mutex<Map<String, Value>>,
    pub kasm: Mutex<Kasm>,
    pub last_active: Mutex<BTreeMap<String, i64>>,
    pub forecast: Mutex<Value>,
    pub curve: Mutex<Vec<Value>>,
    pub activity_cpu: Mutex<Option<crate::model::CpuSampler>>,
    pub history: Mutex<Vec<Value>>,
    pub timeline: Mutex<Option<(i64, String)>>,
    pub heat: Mutex<Value>,
    // Graph JSON, computed by the ticker: the HTTP handler never touches
    // Postgres itself (a blocking client in the tokio runtime panics).
    pub timeline_body: Mutex<String>,
    pub pg_health: Mutex<Value>,
    pub cached: RwLock<Cached>,
    pub host: String,
}

impl Shared {
    pub fn new(state_dir: &str) -> Self {
        let mut mac = Device::with_initial(None);
        let mut phone = Device::with_initial(None);
        if let Some(raw) = read(&format!("{state_dir}/devices.json")) {
            if let Ok(v) = serde_json::from_str::<Value>(&raw) {
                for (dev, key) in [(&mut mac, "mac"), (&mut phone, "phone")] {
                    let old = &v[key];
                    if let Some(st) = old.get("state").and_then(|s| s.as_str()) {
                        dev.map.insert("state".into(), Value::String(st.into()));
                        dev.last_state = Some(st.to_string());
                    }
                    if let Some(since) = old.get("since").and_then(|s| s.as_i64()) {
                        dev.map.insert("since".into(), Value::from(since));
                    }
                    // we take back the whole object: a page opened in the second
                    // following a restart must not display "hors ligne"
                    if let Some(obj) = old.as_object() {
                        for (k, v) in obj {
                            dev.map.insert(k.clone(), v.clone());
                        }
                        dev.map.insert("stale".into(), Value::Bool(true));
                    }
                }
            }
        }
        let mut last_active = BTreeMap::new();
        if let Some(raw) = read(&format!("{state_dir}/last_active.json")) {
            if let Ok(v) = serde_json::from_str::<Map<String, Value>>(&raw) {
                for (k, val) in v {
                    if let Some(n) = val.as_i64() {
                        last_active.insert(k, n);
                    }
                }
            }
        }
        Shared {
            state_dir: state_dir.to_string(),
            mac: Mutex::new(mac),
            phone: Mutex::new(phone),
            net: Mutex::new(Map::new()),
            kasm: Mutex::new(Kasm::default()),
            last_active: Mutex::new(last_active),
            forecast: Mutex::new(Value::Null),
            curve: Mutex::new(Vec::new()),
            activity_cpu: Mutex::new(None),
            history: Mutex::new(Vec::new()),
            timeline: Mutex::new(None),
            heat: Mutex::new(Value::Null),
            timeline_body: Mutex::new(String::new()),
            pg_health: Mutex::new(Value::Null),
            cached: RwLock::new(Cached::default()),
            host: hostname(),
        }
    }

    pub fn save_last_active(&self) {
        let la = self.last_active.lock().unwrap();
        let map: Map<String, Value> =
            la.iter().map(|(k, v)| (k.clone(), Value::from(*v))).collect();
        write_atomic(
            &format!("{}/last_active.json", self.state_dir),
            &Value::Object(map).to_string(),
        );
    }
}

pub fn hostname() -> String {
    read("/proc/sys/kernel/hostname").map(|s| s.trim().to_string()).unwrap_or_default()
}

// ------------------------------------------------------------------ places

/// Location of an unknown gateway, learned from observations: office hours
/// on >= 3 distinct days => "work", otherwise "out". `places.json` can force
/// a label by hand.
pub fn place_label(state_dir: &str, gw_mac: &str) -> String {
    let path = format!("{state_dir}/places.json");
    let mut places: Map<String, Value> = read(&path)
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default();
    let mut entry = places
        .get(gw_mac)
        .and_then(|v| v.as_object())
        .cloned()
        .unwrap_or_default();
    let tm = crate::util::local_tm(now());
    let office = (1..=5).contains(&tm.tm_wday) && (9..19).contains(&tm.tm_hour);
    let key = if office { "office" } else { "other" };
    let n = entry.get(key).and_then(|v| v.as_u64()).unwrap_or(0);
    entry.insert(key.into(), Value::from(n + 1));
    let day = crate::util::ymd(now());
    let mut days: Vec<String> = entry
        .get("days")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|d| d.as_str().map(String::from)).collect())
        .unwrap_or_default();
    if !days.iter().any(|d| d == &day) {
        days.push(day);
        if days.len() > 30 {
            days.remove(0);
        }
    }
    entry.insert("days".into(), Value::from(days.clone()));
    entry.insert("last".into(), Value::from(now()));
    places.insert(gw_mac.to_string(), Value::Object(entry.clone()));
    write_atomic(&path, &Value::Object(places).to_string());
    if let Some(l) = entry.get("label").and_then(|v| v.as_str()) {
        return l.to_string();
    }
    let office = entry.get("office").and_then(|v| v.as_u64()).unwrap_or(0);
    let other = entry.get("other").and_then(|v| v.as_u64()).unwrap_or(0);
    if days.len() >= 3 && office > 2 * other {
        "work".into()
    } else {
        "out".into()
    }
}
