//! typer-core: the engine shared by the web server and the terminal client.
//!
//! Word pools, the local typing run, the room protocol and the RFC 6455 frame
//! layer live here on purpose: the browser client (`web/race.js`), the server
//! and the TUI speak one wire format, and keeping the types in one crate means
//! they cannot drift apart.

pub mod coders;
pub mod ws;

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Instant;

use serde::Deserialize;

/// Word lists a race may use. The code lists are left out on purpose: a 30 s
/// race over punctuation measures the quote key, not typing.
pub const LANGS: [(&str, &str); 4] = [
    ("english200", "english 200"),
    ("english1000", "english 1000"),
    ("french200", "français 200"),
    ("french1000", "français 1000"),
];

pub const RACE_LANGS: [&str; 4] = ["english200", "english1000", "french200", "french1000"];
pub const AMOUNTS: [u32; 4] = [15, 30, 60, 120];

/// No O/0/I/1/L: a room code is read out loud or typed by hand.
pub const CODE_ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";
pub const CODE_LEN: usize = 4;
pub const MAX_NAME: usize = 20;
pub const MAX_MESSAGE: usize = 8192;

pub fn default_lang(ui: &str) -> &'static str {
    if ui == "fr" {
        "french200"
    } else {
        "english200"
    }
}

pub fn lang_label(id: &str) -> &str {
    LANGS
        .iter()
        .find(|(key, _)| *key == id)
        .map(|(_, label)| *label)
        .unwrap_or(id)
}

// ------------------------------------------------------------------ random ---

/// xorshift64*: word streams and room codes do not need a cryptographic RNG,
/// and this keeps the dependency tree to serde.
#[derive(Debug, Clone)]
pub struct Rng(u64);

impl Rng {
    pub fn seeded(seed: u64) -> Self {
        Self(if seed == 0 {
            0x9E37_79B9_7F4A_7C15
        } else {
            seed
        })
    }

    pub fn from_entropy() -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x1234_5678_9ABC_DEF0);
        Self::seeded(nanos ^ (std::process::id() as u64).rotate_left(32))
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    pub fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            (self.next_u64() % n as u64) as usize
        }
    }

    /// Six random hex characters, the player id the browser also gets.
    pub fn token(&mut self) -> String {
        format!("{:012x}", self.next_u64() >> 16)
    }

    pub fn mask(&mut self) -> [u8; 4] {
        let v = self.next_u64().to_le_bytes();
        [v[0], v[1], v[2], v[3]]
    }
}

// ------------------------------------------------------------------- pools ---

/// Word pools read from the web root (`lang/<id>`), one list per race language.
#[derive(Debug, Clone, Default)]
pub struct Pools {
    lists: Vec<(String, Vec<String>)>,
}

impl Pools {
    pub fn load(root: &Path) -> std::io::Result<Self> {
        let mut lists = Vec::new();
        for id in RACE_LANGS {
            let path: PathBuf = root.join("lang").join(id);
            let text = std::fs::read_to_string(&path).unwrap_or_default();
            let words: Vec<String> = text.split_whitespace().map(str::to_string).collect();
            if words.len() >= 20 {
                lists.push((id.to_string(), words));
            }
        }
        Ok(Self { lists })
    }

    pub fn is_empty(&self) -> bool {
        self.lists.is_empty()
    }

    pub fn contains(&self, id: &str) -> bool {
        self.lists.iter().any(|(key, _)| key == id)
    }

    pub fn ids(&self) -> Vec<&str> {
        self.lists.iter().map(|(key, _)| key.as_str()).collect()
    }

    fn pool(&self, lang: &str) -> Option<&Vec<String>> {
        self.lists
            .iter()
            .find(|(key, _)| key == lang)
            .or_else(|| self.lists.iter().find(|(key, _)| key == "english200"))
            .map(|(_, words)| words)
    }

    /// A stream of `count` words, never the same word twice in a row.
    pub fn sample(&self, lang: &str, count: usize, rng: &mut Rng) -> Vec<String> {
        let Some(pool) = self.pool(lang) else {
            return Vec::new();
        };
        let mut out = Vec::with_capacity(count);
        let mut previous: &str = "";
        for _ in 0..count {
            let mut word: &str = pool[rng.below(pool.len())].as_str();
            for _ in 0..8 {
                if word != previous {
                    break;
                }
                word = pool[rng.below(pool.len())].as_str();
            }
            out.push(word.to_string());
            previous = word;
        }
        out
    }

    /// Word count for a timed race: enough text that nobody reaches the end.
    pub fn stream_len(&self, amount: u32) -> usize {
        ((amount as f64 * 4.5) as usize).max(200)
    }
}

// ------------------------------------------------------------------- names ---

pub fn new_code(rng: &mut Rng) -> String {
    (0..CODE_LEN)
        .map(|_| CODE_ALPHABET[rng.below(CODE_ALPHABET.len())] as char)
        .collect()
}

pub fn valid_code(code: &str) -> bool {
    code.len() == CODE_LEN
        && code
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
}

/// Room-safe name: letters, digits, spaces and the three punctuation marks a
/// first name may carry. Duplicates get a counter instead of a silent merge.
pub fn sanitize_name(raw: &str, taken: &HashSet<String>) -> String {
    let cleaned: String = raw
        .chars()
        .filter(|c| c.is_alphanumeric() || matches!(c, ' ' | '-' | '\'' | '.'))
        .collect();
    let trimmed = cleaned.trim();
    let mut name: String = trimmed.chars().take(MAX_NAME).collect();
    if name.is_empty() {
        name = "guest".to_string();
    }
    let base = name.clone();
    let mut n = 2;
    while taken.contains(&name.to_lowercase()) {
        name = format!("{base} {n}").chars().take(MAX_NAME).collect();
        n += 1;
    }
    name
}

// ------------------------------------------------------------------ values ---

/// `amount` arrives as a JSON number from a client and as a string from a form:
/// both are accepted, anything else falls back to the room's current value.
pub fn amount_from(value: &serde_json::Value, fallback: u32) -> u32 {
    let parsed = match value {
        serde_json::Value::Number(n) => n.as_u64().map(|v| v as u32),
        serde_json::Value::String(s) => s.trim().parse::<u32>().ok(),
        _ => None,
    };
    match parsed {
        Some(v) if AMOUNTS.contains(&v) => v,
        _ => fallback,
    }
}

/// Progress numbers come from the browser: clamp them instead of trusting them.
pub fn clamp(value: &serde_json::Value, low: f64, high: f64, fallback: f64) -> f64 {
    let parsed = match value {
        serde_json::Value::Number(n) => n.as_f64(),
        serde_json::Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    };
    match parsed {
        Some(v) if v.is_finite() => {
            let cap = v.max(low).min(high);
            if cap.is_finite() {
                cap
            } else {
                fallback
            }
        }
        _ => fallback,
    }
}

// --------------------------------------------------------------- protocol ---

/// One JSON object per WebSocket text frame, tagged by `t`.
///
/// `#[serde(other)]` makes an unknown tag a no-op instead of a dropped
/// connection: the browser and the TUI will add messages at different times.
#[derive(Debug, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum ClientMsg {
    Join {
        #[serde(default)]
        room: String,
        #[serde(default)]
        name: String,
        #[serde(default)]
        lang: String,
        #[serde(default)]
        amount: serde_json::Value,
    },
    Ready {
        #[serde(default)]
        ready: bool,
    },
    Progress {
        #[serde(default)]
        word: serde_json::Value,
        #[serde(default)]
        chars: serde_json::Value,
        #[serde(default)]
        wpm: serde_json::Value,
        #[serde(default)]
        acc: serde_json::Value,
    },
    Done {
        #[serde(default)]
        word: serde_json::Value,
        #[serde(default)]
        chars: serde_json::Value,
        #[serde(default)]
        wpm: serde_json::Value,
        #[serde(default)]
        acc: serde_json::Value,
    },
    Settings {
        #[serde(default)]
        lang: String,
        #[serde(default)]
        amount: serde_json::Value,
    },
    Start,
    Rematch,
    Leave,
    #[serde(other)]
    Unknown,
}

/// Local typing state. The server owns the words, the clock and the ranking;
/// this only measures what the hands in front of the keyboard did.
#[derive(Debug, Default)]
pub struct Run {
    pub words: Vec<String>,
    pub typed: Vec<String>,
    pub index: usize,
    pub started: bool,
    pub ended: bool,
    start: Option<Instant>,
    pub keys: u32,
    pub errors: u32,
}

impl Run {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Take the server's stream and start the clock on the go signal.
    pub fn mount(&mut self, words: Vec<String>) {
        self.reset();
        self.typed = vec![String::new(); words.len()];
        self.words = words;
        self.started = true;
        self.start = Some(Instant::now());
    }

    pub fn elapsed(&self) -> f64 {
        match self.start {
            Some(at) => at.elapsed().as_secs_f64().max(0.001),
            None => 0.001,
        }
    }

    pub fn correct(&self) -> u32 {
        let mut total = 0;
        for (i, text) in self.typed.iter().enumerate() {
            let Some(word) = self.words.get(i) else {
                continue;
            };
            for (j, typed) in text.chars().enumerate() {
                if word.chars().nth(j) == Some(typed) {
                    total += 1;
                }
            }
        }
        total
    }

    pub fn wpm(&self) -> u32 {
        (self.correct() as f64 / 5.0 / (self.elapsed() / 60.0)).round() as u32
    }

    pub fn acc(&self) -> f64 {
        if self.keys == 0 {
            100.0
        } else {
            (100.0 * (1.0 - self.errors as f64 / self.keys as f64)).max(0.0)
        }
    }

    pub fn feed(&mut self, ch: char) {
        if self.ended || self.words.is_empty() || self.index >= self.words.len() {
            return;
        }
        if self.start.is_none() {
            self.start = Some(Instant::now());
            self.started = true;
        }
        if ch == ' ' {
            let text = self.typed[self.index].clone();
            if text.is_empty() {
                return;
            }
            self.keys += 1;
            if text != self.words[self.index] {
                self.errors += 1;
            }
            if self.index + 1 >= self.words.len() {
                self.ended = true;
            } else {
                self.index += 1;
            }
            return;
        }
        let target: Vec<char> = self.words[self.index].chars().collect();
        let mut text = std::mem::take(&mut self.typed[self.index]);
        let typed_len = text.chars().count();
        if typed_len >= target.len() + 4 {
            self.typed[self.index] = text;
            return;
        }
        self.keys += 1;
        if target.get(typed_len) != Some(&ch) {
            self.errors += 1;
        }
        text.push(ch);
        self.typed[self.index] = text;
    }

    pub fn backspace(&mut self) {
        if self.ended || self.words.is_empty() {
            return;
        }
        let text = self.typed[self.index].clone();
        if !text.is_empty() {
            let mut shortened = text;
            shortened.pop();
            self.typed[self.index] = shortened;
            return;
        }
        if self.index == 0 {
            return;
        }
        let previous = self.index - 1;
        if self.typed[previous] == self.words[previous] {
            return; // only step back into a word that still needs fixing
        }
        self.index = previous;
        let mut shortened = self.typed[previous].clone();
        shortened.pop();
        self.typed[previous] = shortened;
    }

    pub fn snapshot(&self) -> Progress {
        Progress {
            word: self.index,
            chars: self.correct(),
            wpm: self.wpm(),
            acc: (self.acc() * 10.0).round() / 10.0,
        }
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
pub struct Progress {
    pub word: usize,
    pub chars: u32,
    pub wpm: u32,
    pub acc: f64,
}

impl Progress {
    pub fn progress_json(self) -> serde_json::Value {
        serde_json::json!({
            "t": "progress",
            "word": self.word,
            "chars": self.chars,
            "wpm": self.wpm,
            "acc": self.acc,
        })
    }

    pub fn done_json(self) -> serde_json::Value {
        serde_json::json!({
            "t": "done",
            "word": self.word,
            "chars": self.chars,
            "wpm": self.wpm,
            "acc": self.acc,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_are_four_and_unambiguous() {
        let mut rng = Rng::seeded(7);
        for _ in 0..64 {
            let code = new_code(&mut rng);
            assert_eq!(code.len(), CODE_LEN);
            assert!(valid_code(&code), "{code}");
            assert!(!code.contains(['O', '0', 'I', '1', 'L']));
        }
    }

    #[test]
    fn names_are_cleaned_and_deduplicated() {
        let mut taken = HashSet::new();
        taken.insert("marc".to_string());
        assert_eq!(sanitize_name("  marc  ", &taken), "marc 2");
        assert_eq!(sanitize_name("<script>", &taken), "script");
        assert_eq!(sanitize_name("", &taken), "guest");
        assert!(sanitize_name(&"a".repeat(50), &taken).chars().count() <= MAX_NAME);
    }

    #[test]
    fn run_scores_a_perfect_word() {
        let mut run = Run::new();
        run.mount(vec!["ab".to_string(), "cd".to_string()]);
        run.feed('a');
        run.feed('b');
        run.feed(' ');
        assert_eq!(run.index, 1);
        assert_eq!(run.keys, 3);
        assert_eq!(run.errors, 0);
        run.feed('c');
        run.feed('x');
        assert_eq!(run.errors, 1);
        assert_eq!(run.correct(), 3);
        assert_eq!(run.acc(), 100.0 * (1.0 - 1.0 / 5.0));
    }

    #[test]
    fn backspace_only_steps_back_into_a_wrong_word() {
        let mut run = Run::new();
        run.mount(vec!["ab".to_string(), "cd".to_string(), "ef".to_string()]);
        run.feed('a');
        run.feed('b');
        run.feed(' ');
        run.backspace();
        assert_eq!(run.index, 1, "a correct word is not reopened");
        run.feed('c');
        run.feed(' ');
        assert_eq!(run.index, 2);
        run.backspace();
        run.backspace();
        assert_eq!(run.index, 1);
        assert_eq!(run.typed[1], "");
    }

    #[test]
    fn amounts_and_progress_are_clamped() {
        assert_eq!(amount_from(&serde_json::json!(60), 30), 60);
        assert_eq!(amount_from(&serde_json::json!("45"), 30), 30);
        assert_eq!(amount_from(&serde_json::json!(7), 30), 30);
        assert_eq!(clamp(&serde_json::json!(900), 0.0, 400.0, 0.0), 400.0);
        assert_eq!(clamp(&serde_json::json!("nan"), 0.0, 400.0, 12.0), 12.0);
    }
}
