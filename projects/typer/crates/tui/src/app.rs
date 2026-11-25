//! The client state machine: one socket, one local run, the room state as the
//! server tells it.

use std::time::{Duration, Instant};

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::{json, Value};
use typer_core::{Run, AMOUNTS, LANGS};

use crate::client::Client;

pub struct App {
    pub client: Client,
    pub ui: &'static str,
    pub name: String,
    pub lang: String,
    pub amount: u32,
    pub room: String,
    pub state: Option<Value>,
    pub me: Option<String>,
    pub run: Run,
    pub error: String,
    pub quit: bool,
    last_send: Instant,
    reported: bool,
}

impl App {
    pub fn new(client: Client, name: String, lang: String, amount: u32, ui: &'static str) -> Self {
        Self {
            client,
            ui,
            name,
            lang,
            amount,
            room: String::new(),
            state: None,
            me: None,
            run: Run::new(),
            error: String::new(),
            quit: false,
            last_send: Instant::now(),
            reported: false,
        }
    }

    pub fn join(&mut self, room: &str) -> Result<(), String> {
        self.client.send(&json!({
            "t": "join",
            "room": room,
            "name": self.name,
            "lang": self.lang,
            "amount": self.amount,
        }))
    }

    pub fn phase(&self) -> Option<&str> {
        self.state
            .as_ref()
            .and_then(|state| state["phase"].as_str())
    }

    pub fn set_ready(&mut self, ready: bool) -> Result<(), String> {
        self.client.send(&json!({ "t": "ready", "ready": ready }))
    }

    /// Host only, lobby only: nobody else is coming, start the race anyway.
    /// This is what lets `--probe` (and a deliberately solo run) start alone.
    pub fn start(&mut self) -> Result<(), String> {
        self.client.send(&json!({ "t": "start" }))
    }

    pub fn send_progress(&mut self) -> Result<(), String> {
        self.client.send(&self.run.snapshot().progress_json())
    }

    pub fn send_done(&mut self) -> Result<(), String> {
        if self.reported {
            return Ok(());
        }
        self.reported = true;
        self.client.send(&self.run.snapshot().done_json())
    }

    pub fn is_host(&self) -> bool {
        match (&self.me, self.state.as_ref()) {
            (Some(me), Some(state)) => state["host"].as_str() == Some(me.as_str()),
            _ => false,
        }
    }

    pub fn me_player(&self) -> Option<&Value> {
        let me = self.me.as_ref()?;
        self.state
            .as_ref()?
            .get("players")?
            .as_array()?
            .iter()
            .find(|player| player["id"].as_str() == Some(me.as_str()))
    }

    /// Standings ordered by rank, then by progress.
    pub fn board(&self) -> Vec<Value> {
        let Some(state) = self.state.as_ref() else {
            return Vec::new();
        };
        let mut rows: Vec<Value> = state
            .get("standings")
            .or_else(|| state.get("players"))
            .and_then(|value| value.as_array())
            .cloned()
            .unwrap_or_default();
        rows.sort_by(|a, b| {
            let rank = |row: &Value| row["rank"].as_i64().unwrap_or(99);
            rank(a).cmp(&rank(b)).then_with(|| {
                b["chars"]
                    .as_i64()
                    .unwrap_or(0)
                    .cmp(&a["chars"].as_i64().unwrap_or(0))
            })
        });
        rows
    }

    /// Drain everything the socket has, without blocking the UI.
    pub fn pump(&mut self) -> Result<(), String> {
        while let Some(message) = self.client.poll(Duration::from_millis(0))? {
            self.apply(message);
        }
        Ok(())
    }

    fn apply(&mut self, message: Value) {
        match message["t"].as_str() {
            Some("error") => {
                self.error = format!(
                    "{}: {}",
                    crate::ui::t(self.ui, "error"),
                    message["error"].as_str().unwrap_or("?")
                );
            }
            Some("state") => {
                let previous = self.phase().map(str::to_string);
                let phase = message["phase"].as_str().unwrap_or("lobby").to_string();
                if let Some(room) = message["room"].as_str() {
                    self.room = room.to_string();
                }
                if let Some(you) = message["you"].as_str() {
                    self.me = Some(you.to_string());
                }
                if phase == "race" && previous.as_deref() != Some("race") {
                    let words: Vec<String> = message["words"]
                        .as_array()
                        .map(|words| {
                            words
                                .iter()
                                .filter_map(|word| word.as_str().map(str::to_string))
                                .collect()
                        })
                        .unwrap_or_default();
                    self.run.mount(words);
                    self.reported = false;
                    self.error.clear();
                }
                if phase == "lobby"
                    && matches!(
                        previous.as_deref(),
                        Some("done") | Some("race") | Some("countdown")
                    )
                {
                    self.run.reset();
                }
                if phase == "done" {
                    self.run.ended = true;
                }
                if phase != "race" && phase != "done" {
                    self.run.started = false;
                }
                self.state = Some(message);
            }
            _ => {}
        }
    }

    /// Called at every loop turn: progress twice a second, `done` once.
    pub fn tick(&mut self) -> Result<(), String> {
        self.pump()?;
        let phase = self.phase().unwrap_or("lobby").to_string();
        if phase == "race" {
            if self.last_send.elapsed() >= Duration::from_millis(400) {
                self.last_send = Instant::now();
                self.send_progress()?;
            }
            if self.run.ended {
                self.send_done()?;
            }
        }
        Ok(())
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> bool {
        if key.modifiers.contains(KeyModifiers::CONTROL)
            && matches!(key.code, KeyCode::Char('c') | KeyCode::Char('C'))
        {
            return false;
        }
        let phase = self.phase().unwrap_or("lobby").to_string();
        match key.code {
            KeyCode::Esc => return false,
            KeyCode::Backspace => self.run.backspace(),
            KeyCode::Char('q') if phase != "race" => return false,
            KeyCode::Char('r') if phase == "lobby" => {
                let ready = self
                    .me_player()
                    .and_then(|me| me["ready"].as_bool())
                    .unwrap_or(false);
                let _ = self.set_ready(!ready);
            }
            KeyCode::Char('r') if phase == "done" => {
                let _ = self.client.send(&json!({ "t": "rematch" }));
            }
            KeyCode::Char('t') if phase == "lobby" && self.is_host() => {
                self.amount = next_amount(self.amount);
                self.push_settings();
            }
            KeyCode::Char('l') if phase == "lobby" && self.is_host() => {
                self.lang = next_lang(&self.lang);
                self.push_settings();
            }
            KeyCode::Char(ch) if phase == "race" => self.run.feed(ch),
            _ => {}
        }
        true
    }

    fn push_settings(&mut self) {
        let _ = self.client.send(&json!({
            "t": "settings",
            "lang": self.lang,
            "amount": self.amount,
        }));
    }
}

pub fn next_amount(current: u32) -> u32 {
    let index = AMOUNTS
        .iter()
        .position(|value| *value == current)
        .unwrap_or(1);
    AMOUNTS[(index + 1) % AMOUNTS.len()]
}

pub fn next_lang(current: &str) -> String {
    let ids: Vec<&str> = LANGS.iter().map(|(id, _)| *id).collect();
    let index = ids.iter().position(|id| *id == current).unwrap_or(0);
    ids[(index + 1) % ids.len()].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn amounts_and_languages_cycle() {
        assert_eq!(next_amount(15), 30);
        assert_eq!(next_amount(120), 15);
        assert_eq!(next_amount(7), 60);
        assert_eq!(next_lang("english200"), "english1000");
        assert_eq!(next_lang("french1000"), "english200");
    }
}
