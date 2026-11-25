//! The race hub: one task owns every room.
//!
//! Sockets never share room state: they send messages here over a channel and
//! receive already-framed bytes back. That removes every lock from the hot path
//! (a broadcast is a `send` per player) and keeps rooms deterministic: one
//! countdown, one clock, one ranking.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use typer_core::ws;
use typer_core::{amount_from, clamp, new_code, sanitize_name, valid_code, ClientMsg, Pools, Rng};

pub const MAX_ROOMS: usize = 200;
pub const MAX_PLAYERS: usize = 12;
const COUNTDOWN: f64 = 3.0;
const IDLE_TIMEOUT: Duration = Duration::from_secs(3600);
const EMPTY_TIMEOUT: Duration = Duration::from_secs(120);
const TICK: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Lobby,
    Countdown,
    Race,
    Done,
}

impl Phase {
    fn as_str(self) -> &'static str {
        match self {
            Phase::Lobby => "lobby",
            Phase::Countdown => "countdown",
            Phase::Race => "race",
            Phase::Done => "done",
        }
    }
}

pub struct Player {
    pub pid: String,
    pub name: String,
    pub wpm: f64,
    pub acc: f64,
    pub word: i64,
    pub chars: i64,
    pub ready: bool,
    pub done: bool,
    pub tx: UnboundedSender<Vec<u8>>,
}

impl Player {
    fn public(&self) -> Value {
        json!({
            "id": self.pid,
            "name": self.name,
            "wpm": self.wpm.round() as i64,
            "acc": (self.acc * 10.0).round() / 10.0,
            "progress": self.word,
            "chars": self.chars,
            "ready": self.ready,
            "done": self.done,
        })
    }
}

pub struct Room {
    pub code: String,
    pub lang: String,
    pub amount: u32,
    pub phase: Phase,
    pub host: Option<String>,
    pub words: Vec<String>,
    pub players: Vec<Player>,
    pub starts_in: f64,
    countdown_at: Option<Instant>,
    race_end: Option<Instant>,
    touched: Instant,
}

impl Room {
    fn new(code: String, lang: String, amount: u32) -> Self {
        let now = Instant::now();
        Self {
            code,
            lang,
            amount,
            phase: Phase::Lobby,
            host: None,
            words: Vec::new(),
            players: Vec::new(),
            starts_in: 0.0,
            countdown_at: None,
            race_end: None,
            touched: now,
        }
    }

    fn ranking(&self) -> Vec<Value> {
        let mut rows: Vec<(bool, i64, f64, Value)> = self
            .players
            .iter()
            .map(|p| (!p.done, p.chars, p.wpm, p.public()))
            .collect();
        rows.sort_by(|a, b| {
            a.0.cmp(&b.0)
                .then_with(|| b.1.cmp(&a.1))
                .then_with(|| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal))
        });
        rows.into_iter()
            .enumerate()
            .map(|(i, (_, _, _, mut row))| {
                row["rank"] = json!(i + 1);
                row
            })
            .collect()
    }

    /// The state of the room as one viewer sees it: `you` differs per socket,
    /// and a client that read somebody else's id would think it is the host.
    fn state(&self, you: &str, now: Instant) -> Value {
        let ends_in = match (self.phase, self.race_end) {
            (Phase::Race, Some(end)) => {
                (end.saturating_duration_since(now).as_secs_f64() * 10.0).round() / 10.0
            }
            _ => 0.0,
        };
        let words = match self.phase {
            Phase::Race | Phase::Done => json!(self.words),
            _ => json!([]),
        };
        let players: Vec<Value> = self.players.iter().map(Player::public).collect();
        json!({
            "t": "state",
            "room": self.code,
            "phase": self.phase.as_str(),
            "host": self.host,
            "you": you,
            "lang": self.lang,
            "amount": self.amount,
            "startsIn": self.starts_in,
            "endsIn": ends_in,
            "words": words,
            "players": players,
            "standings": self.ranking(),
        })
    }
}

pub enum HubMsg {
    Join {
        conn: u64,
        room: String,
        name: String,
        lang: String,
        amount: Value,
        tx: UnboundedSender<Vec<u8>>,
    },
    Command {
        conn: u64,
        msg: ClientMsg,
    },
    Gone {
        conn: u64,
    },
}

pub fn spawn(pools: Pools) -> UnboundedSender<HubMsg> {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    tokio::spawn(run(pools, rx));
    tx
}

async fn run(pools: Pools, mut rx: UnboundedReceiver<HubMsg>) {
    let mut hub = Hub {
        pools,
        rng: Rng::from_entropy(),
        rooms: HashMap::new(),
        seats: HashMap::new(),
        tick: 0,
    };
    let mut ticker = tokio::time::interval(TICK);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            biased;
            message = rx.recv() => match message {
                Some(message) => hub.handle(message),
                None => break,
            },
            _ = ticker.tick() => hub.on_tick(),
        }
    }
}

/// `start` is the host's private lever: it is how a deliberate solo run (and
/// `typer-race --probe`) begins without a second player. A guest sending it
/// would launch a race the room never agreed to, so the phase alone is not
/// enough to accept it.
fn may_start(room: &Room, pid: &str) -> bool {
    room.phase == Phase::Lobby && room.host.as_deref() == Some(pid)
}

struct Hub {
    pools: Pools,
    rng: Rng,
    rooms: HashMap<String, Room>,
    /// connection id -> (room code, player id)
    seats: HashMap<u64, (String, String)>,
    tick: u64,
}

impl Hub {
    fn handle(&mut self, message: HubMsg) {
        match message {
            HubMsg::Join {
                conn,
                room,
                name,
                lang,
                amount,
                tx,
            } => self.join(conn, room, name, lang, amount, tx),
            HubMsg::Command { conn, msg } => self.command(conn, msg),
            HubMsg::Gone { conn } => self.gone(conn),
        }
    }

    // ------------------------------------------------------------ seats ---

    fn reject(tx: &UnboundedSender<Vec<u8>>, code: &str) {
        let payload = json!({ "t": "error", "error": code }).to_string();
        let _ = tx.send(ws::encode(payload.as_bytes(), 0x1));
    }

    fn join(
        &mut self,
        conn: u64,
        room: String,
        name: String,
        lang: String,
        amount: Value,
        tx: UnboundedSender<Vec<u8>>,
    ) {
        if self.seats.contains_key(&conn) {
            return;
        }
        let requested = room.trim().to_uppercase();
        if !requested.is_empty() && !valid_code(&requested) {
            return Self::reject(&tx, "badcode");
        }

        let code = if requested.is_empty() {
            if self.rooms.len() >= MAX_ROOMS {
                return Self::reject(&tx, "server_full");
            }
            let mut code = new_code(&mut self.rng);
            while self.rooms.contains_key(&code) {
                code = new_code(&mut self.rng);
            }
            let lang = if self.pools.contains(&lang) {
                lang
            } else {
                "english200".to_string()
            };
            let mut created = Room::new(code.clone(), lang, amount_from(&amount, 30));
            let (lang, count) = (created.lang.clone(), self.pools.stream_len(created.amount));
            created.words = self.pools.sample(&lang, count, &mut self.rng);
            self.rooms.insert(code.clone(), created);
            code
        } else {
            if !self.rooms.contains_key(&requested) {
                // An explicit code that does not exist is a typo, not a request
                // to open a room on that name: say so instead of splitting the
                // group into two rooms.
                return Self::reject(&tx, "no_room");
            }
            requested
        };

        let (pid, name) = {
            let Some(room) = self.rooms.get_mut(&code) else {
                return;
            };
            if room.phase != Phase::Lobby {
                return Self::reject(&tx, "race_started");
            }
            if room.players.len() >= MAX_PLAYERS {
                return Self::reject(&tx, "room_full");
            }
            let taken: HashSet<String> =
                room.players.iter().map(|p| p.name.to_lowercase()).collect();
            let name = sanitize_name(&name, &taken);
            let pid = self.rng.token();
            room.players.push(Player {
                pid: pid.clone(),
                name: name.clone(),
                wpm: 0.0,
                acc: 100.0,
                word: 0,
                chars: 0,
                ready: false,
                done: false,
                tx: tx.clone(),
            });
            if room.host.is_none() {
                room.host = Some(pid.clone());
            }
            room.touched = Instant::now();
            (pid, name)
        };

        self.seats.insert(conn, (code.clone(), pid.clone()));
        let _ = name;
        self.send_to(&code, &pid);
        self.broadcast(&code);
    }

    fn gone(&mut self, conn: u64) {
        let Some((code, pid)) = self.seats.remove(&conn) else {
            return;
        };
        let Some(room) = self.rooms.get_mut(&code) else {
            return;
        };
        room.players.retain(|p| p.pid != pid);
        if room.host.as_deref() == Some(pid.as_str()) {
            room.host = room.players.first().map(|p| p.pid.clone());
        }
        room.touched = Instant::now();
        self.broadcast(&code);
    }

    // --------------------------------------------------------- commands ---

    fn command(&mut self, conn: u64, msg: ClientMsg) {
        let Some((code, pid)) = self.seats.get(&conn).cloned() else {
            return;
        };
        match msg {
            ClientMsg::Join { .. } | ClientMsg::Leave | ClientMsg::Unknown => return,
            ClientMsg::Start => {
                if self
                    .rooms
                    .get(&code)
                    .map(|r| may_start(r, &pid))
                    .unwrap_or(false)
                {
                    self.start_race(&code);
                }
            }
            ClientMsg::Rematch => {
                if self
                    .rooms
                    .get(&code)
                    .map(|r| r.phase == Phase::Done)
                    .unwrap_or(false)
                {
                    self.rematch(&code);
                }
            }
            ClientMsg::Settings { lang, amount } => self.settings(&code, &pid, &lang, &amount),
            ClientMsg::Ready { ready } => {
                let mut everyone_ready = false;
                if let Some(room) = self.rooms.get_mut(&code) {
                    room.touched = Instant::now();
                    if room.phase == Phase::Lobby {
                        if let Some(player) = room.players.iter_mut().find(|p| p.pid == pid) {
                            player.ready = ready;
                        }
                        // Two players minimum: a lone host pressing ready used
                        // to start a solo race that then refused the friend the
                        // room was created for. `Start` (host only) is the way
                        // to race alone.
                        everyone_ready =
                            room.players.len() >= 2 && room.players.iter().all(|p| p.ready);
                    }
                }
                if everyone_ready {
                    self.start_race(&code);
                }
            }
            ClientMsg::Progress {
                word,
                chars,
                wpm,
                acc,
            } => {
                if let Some(room) = self.rooms.get_mut(&code) {
                    room.touched = Instant::now();
                    if matches!(room.phase, Phase::Race | Phase::Done) {
                        let words = room.words.len();
                        if let Some(player) = room.players.iter_mut().find(|p| p.pid == pid) {
                            update_progress(player, &word, &chars, &wpm, &acc, words);
                        }
                    }
                }
            }
            ClientMsg::Done {
                word,
                chars,
                wpm,
                acc,
            } => {
                if let Some(room) = self.rooms.get_mut(&code) {
                    room.touched = Instant::now();
                    if room.phase == Phase::Race {
                        let words = room.words.len();
                        if let Some(player) = room.players.iter_mut().find(|p| p.pid == pid) {
                            update_progress(player, &word, &chars, &wpm, &acc, words);
                            player.done = true;
                        }
                    }
                }
            }
        }
        self.broadcast(&code);
    }

    fn settings(&mut self, code: &str, pid: &str, lang: &str, amount: &Value) {
        let lang_known = self.pools.contains(lang);
        let Some(room) = self.rooms.get_mut(code) else {
            return;
        };
        if room.phase != Phase::Lobby || room.host.as_deref() != Some(pid) {
            return;
        }
        if lang_known {
            room.lang = lang.to_string();
        }
        room.amount = amount_from(amount, room.amount);
        let (lang, count) = (room.lang.clone(), self.pools.stream_len(room.amount));
        room.words = self.pools.sample(&lang, count, &mut self.rng);
        for player in room.players.iter_mut() {
            player.ready = false;
        }
        room.touched = Instant::now();
    }

    fn start_race(&mut self, code: &str) {
        let Some(room) = self.rooms.get_mut(code) else {
            return;
        };
        if room.phase != Phase::Lobby || room.players.is_empty() {
            return;
        }
        room.phase = Phase::Countdown;
        room.starts_in = COUNTDOWN;
        room.countdown_at = Some(Instant::now() + Duration::from_secs_f64(COUNTDOWN));
        room.race_end = None;
        for player in room.players.iter_mut() {
            player.word = 0;
            player.chars = 0;
            player.wpm = 0.0;
            player.acc = 100.0;
            player.done = false;
        }
        room.touched = Instant::now();
    }

    fn rematch(&mut self, code: &str) {
        let Some(room) = self.rooms.get_mut(code) else {
            return;
        };
        if room.phase != Phase::Done {
            return;
        }
        room.phase = Phase::Lobby;
        room.starts_in = 0.0;
        room.countdown_at = None;
        room.race_end = None;
        let (lang, count) = (room.lang.clone(), self.pools.stream_len(room.amount));
        room.words = self.pools.sample(&lang, count, &mut self.rng);
        for player in room.players.iter_mut() {
            player.word = 0;
            player.chars = 0;
            player.wpm = 0.0;
            player.acc = 100.0;
            player.done = false;
            player.ready = false;
        }
        room.touched = Instant::now();
    }

    // ------------------------------------------------------------ clock ---

    fn on_tick(&mut self) {
        self.tick = self.tick.wrapping_add(1);
        let now = Instant::now();
        let mut dirty: Vec<String> = Vec::new();

        for (code, room) in self.rooms.iter_mut() {
            match room.phase {
                Phase::Countdown => {
                    let Some(at) = room.countdown_at else {
                        room.phase = Phase::Race;
                        room.race_end = Some(now + Duration::from_secs(room.amount as u64));
                        dirty.push(code.clone());
                        continue;
                    };
                    let left = at.saturating_duration_since(now).as_secs_f64();
                    if left <= 0.0 {
                        room.phase = Phase::Race;
                        room.starts_in = 0.0;
                        room.countdown_at = None;
                        room.race_end = Some(now + Duration::from_secs(room.amount as u64));
                        dirty.push(code.clone());
                    } else {
                        let whole = left.ceil();
                        if (whole - room.starts_in).abs() > f64::EPSILON {
                            room.starts_in = whole;
                            dirty.push(code.clone());
                        }
                    }
                }
                Phase::Race => {
                    if let Some(end) = room.race_end {
                        if now >= end {
                            room.phase = Phase::Done;
                            room.race_end = None;
                            room.starts_in = 0.0;
                            dirty.push(code.clone());
                            continue;
                        }
                    }
                    // Standings twice a second: progress frames stay cheap,
                    // the screens stay live.
                    if self.tick.is_multiple_of(5) {
                        dirty.push(code.clone());
                    }
                }
                Phase::Lobby | Phase::Done => {}
            }
        }

        for code in dirty {
            self.broadcast(&code);
        }

        if self.tick.is_multiple_of(600) {
            self.sweep(now);
        }
    }

    fn sweep(&mut self, now: Instant) {
        let stale: Vec<String> = self
            .rooms
            .values()
            .filter(|room| {
                let idle = now.duration_since(room.touched);
                (room.players.is_empty() && idle > EMPTY_TIMEOUT) || idle > IDLE_TIMEOUT
            })
            .map(|room| room.code.clone())
            .collect();
        for code in stale {
            self.rooms.remove(&code);
            self.seats.retain(|_, (seat, _)| seat != &code);
        }
    }

    // -------------------------------------------------------- broadcast ---

    fn send_to(&self, code: &str, pid: &str) {
        let Some(room) = self.rooms.get(code) else {
            return;
        };
        let now = Instant::now();
        if let Some(player) = room.players.iter().find(|p| p.pid == pid) {
            let payload = room.state(pid, now).to_string();
            let _ = player.tx.send(ws::encode(payload.as_bytes(), 0x1));
        }
    }

    fn broadcast(&mut self, code: &str) {
        let now = Instant::now();
        let mut dead: Vec<String> = Vec::new();
        {
            let Some(room) = self.rooms.get(code) else {
                return;
            };
            for player in room.players.iter() {
                let payload = room.state(&player.pid, now).to_string();
                if player.tx.send(ws::encode(payload.as_bytes(), 0x1)).is_err() {
                    dead.push(player.pid.clone());
                }
            }
        }
        if dead.is_empty() {
            return;
        }
        let Some(room) = self.rooms.get_mut(code) else {
            return;
        };
        room.players.retain(|p| !dead.contains(&p.pid));
        if room
            .host
            .as_ref()
            .map(|host| dead.contains(host))
            .unwrap_or(false)
        {
            room.host = room.players.first().map(|p| p.pid.clone());
        }
        room.touched = Instant::now();
    }
}

fn update_progress(
    player: &mut Player,
    word: &Value,
    chars: &Value,
    wpm: &Value,
    acc: &Value,
    words: usize,
) {
    player.word = clamp(word, 0.0, words as f64, player.word as f64) as i64;
    player.chars = clamp(chars, 0.0, 200_000.0, player.chars as f64) as i64;
    player.wpm = clamp(wpm, 0.0, 400.0, player.wpm);
    player.acc = clamp(acc, 0.0, 100.0, player.acc);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn room() -> Room {
        let mut room = Room::new("ABCD".to_string(), "english200".to_string(), 30);
        room.words = vec!["a".to_string(), "b".to_string()];
        room
    }

    fn player(pid: &str, done: bool, chars: i64, wpm: f64) -> Player {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        Player {
            pid: pid.to_string(),
            name: pid.to_string(),
            wpm,
            acc: 100.0,
            word: 0,
            chars,
            ready: false,
            done,
            tx,
        }
    }

    #[test]
    fn ranking_puts_finishers_first_then_progress() {
        let mut room = room();
        room.players.push(player("slow", false, 10, 40.0));
        room.players.push(player("fast", true, 5, 30.0));
        room.players.push(player("fastest", false, 60, 90.0));
        let ranks: Vec<String> = room
            .ranking()
            .iter()
            .map(|row| row["id"].as_str().unwrap_or("").to_string())
            .collect();
        assert_eq!(ranks, vec!["fast", "fastest", "slow"]);
    }

    #[test]
    fn state_hides_the_stream_before_the_race() {
        let room = room();
        let lobby = room.state("p1", Instant::now());
        assert_eq!(lobby["phase"], "lobby");
        assert_eq!(lobby["words"].as_array().map(Vec::len), Some(0));
        assert_eq!(lobby["you"], "p1");
    }

    #[test]
    fn only_the_host_may_start_a_race() {
        let mut room = room();
        room.host = Some("host".to_string());
        assert!(may_start(&room, "host"));
        assert!(!may_start(&room, "guest"));

        // Once the race is running the lever is dead for everybody.
        room.phase = Phase::Race;
        assert!(!may_start(&room, "host"));

        // A room without a host (all gone) cannot be started by a passer-by.
        room.phase = Phase::Lobby;
        room.host = None;
        assert!(!may_start(&room, "guest"));
    }
}
