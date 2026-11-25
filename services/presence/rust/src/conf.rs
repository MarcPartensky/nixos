//! Channel and device configuration, so that this service is not
//! marc's and nobody else's.
//!
//! No machine name is hard-coded: `presence.json` (in the state dir)
//! declares which device each Hermes source maps to, and which sources
//! are automation. Without that file, the default values
//! reproduce the historical behaviour, so an existing install keeps
//! working without writing anything.
//!
//! Minimal example, for someone else:
//!
//! ```json
//! {
//!   "devices": ["laptop", "pixel", "nas"],
//!   "channels": {"desktop": "laptop", "api_server": "pixel", "cli": "nas"},
//!   "automation_sources": ["cron", "heartbeat", "worker"]
//! }
//! ```

use serde_json::{Map, Value};

use crate::util::read;

pub struct Conf {
    /// Declared devices (informational: the service probes what the `probes`
    /// module knows how to probe, but the names used everywhere else come
    /// from here).
    pub devices: Vec<String>,
    /// Hermes source -> device identifier.
    pub channels: Vec<(String, String)>,
    /// Sources that must NEVER count as user presence.
    pub automation_sources: Vec<String>,
}

fn defaults() -> Conf {
    let pairs = [
        ("desktop", "mac"),
        ("api_server", "phone"),
        ("tui", "tower"),
        ("cli", "tower"),
        ("local", "tower"),
        ("matrix", "tower"),
        ("discord", "tower"),
        ("telegram", "tower"),
        ("signal", "tower"),
        ("whatsapp", "tower"),
    ];
    Conf {
        devices: vec!["mac".into(), "phone".into(), "tower".into()],
        channels: pairs
            .iter()
            .map(|(a, b)| (a.to_string(), b.to_string()))
            .collect(),
        automation_sources: vec![
            "cron".into(),
            "heartbeat".into(),
            "worker".into(),
            "subagent".into(),
            "delegation".into(),
            "task".into(),
        ],
    }
}

pub fn load(state_dir: &str) -> Conf {
    let mut conf = defaults();
    let Some(raw) = read(&format!("{state_dir}/presence.json")) else {
        return conf;
    };
    let Ok(v) = serde_json::from_str::<Value>(&raw) else {
        // A broken file must not take the service down: we keep the
        // defaults and the page keeps displaying something coherent.
        return conf;
    };
    if let Some(arr) = v.get("devices").and_then(|x| x.as_array()) {
        let list: Vec<String> = arr
            .iter()
            .filter_map(|d| d.as_str().map(String::from))
            .collect();
        if !list.is_empty() {
            conf.devices = list;
        }
    }
    if let Some(obj) = v.get("channels").and_then(|x| x.as_object()) {
        let mut channels: Vec<(String, String)> = Vec::new();
        for (src, dev) in obj {
            if let Some(d) = dev.as_str() {
                channels.push((src.clone(), d.to_string()));
            }
        }
        if !channels.is_empty() {
            conf.channels = channels;
        }
    }
    if let Some(arr) = v.get("automation_sources").and_then(|x| x.as_array()) {
        let list: Vec<String> = arr
            .iter()
            .filter_map(|d| d.as_str().map(String::from))
            .collect();
        conf.automation_sources = list;
    }
    conf
}

impl Conf {
    /// Device associated with a Hermes source. `None` = unknown source: it then
    /// does not serve as a presence hint, which is the safe behaviour.
    pub fn device_for(&self, source: &str) -> Option<String> {
        self.channels
            .iter()
            .find(|(s, _)| s == source)
            .map(|(_, d)| d.clone())
    }

    pub fn is_automation(&self, source: &str) -> bool {
        self.automation_sources.iter().any(|s| s == source)
    }

    /// SQL list of user sources, for the `in (...)` clause.
    pub fn interactive_sources_sql(&self) -> String {
        let list: Vec<String> = self
            .channels
            .iter()
            .map(|(s, _)| s.clone())
            .filter(|s| !self.is_automation(s))
            .map(|s| format!("'{s}'"))
            .collect();
        if list.is_empty() {
            "''".to_string()
        } else {
            list.join(",")
        }
    }

    /// SQL list of automation sources, for the `not in (...)` clause.
    pub fn automation_sources_sql(&self) -> String {
        let list: Vec<String> = self
            .automation_sources
            .iter()
            .map(|s| format!("'{s}'"))
            .collect();
        if list.is_empty() {
            "''".to_string()
        } else {
            list.join(",")
        }
    }

    /// JSON view of the effective config, so that the page can display it.
    pub fn to_json(&self) -> Value {
        let mut ch = Map::new();
        for (s, d) in &self.channels {
            ch.insert(s.clone(), Value::from(d.clone()));
        }
        serde_json::json!({
            "devices": self.devices,
            "channels": ch,
            "automation_sources": self.automation_sources,
        })
    }
}
