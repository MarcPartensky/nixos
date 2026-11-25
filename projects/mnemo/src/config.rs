//! Runtime configuration, entirely from the environment.
//!
//! Every path has a default that works both on the host (hermes' home) and
//! inside the k3s pod (where the Hermes home is mounted at /data).

use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct Config {
    /// Postgres URL. `None` means dry run: nothing is persisted.
    pub db: Option<String>,
    /// Hermes session database (sqlite, opened read-only).
    pub sessions_db: PathBuf,
    /// OpenAI-compatible base URL, without the trailing /chat/completions.
    pub llm_url: String,
    pub llm_model: String,
    pub llm_key: Option<String>,
    /// Read the key from a file instead of the environment: nothing secret on
    /// a command line, where every process on the host can read it.
    pub llm_key_file: Option<PathBuf>,
    /// Ask the provider to keep the request out of its training/logging path.
    pub llm_zdr: bool,
    /// The hub already runs the podcast pipeline; mnemo only enqueues into it.
    pub hub_url: String,
    pub hub_token_file: PathBuf,
    /// Directory the generated typing word list is written to.
    pub typer_dir: PathBuf,
    /// Directory the explanation sheets are mirrored to, one markdown per
    /// conversation: the site and the podcast read them without the database.
    pub brief_dir: PathBuf,
    pub bind: String,
    pub port: u16,
    /// Bearer token for /api and /mcp (Pangolin SSO covers the browser).
    pub token_file: PathBuf,
    /// Below this priority a conversation is scored but gets no brief.
    pub min_priority: f64,
    pub brief_tokens: u32,
    /// Output budget per scoring call. A reasoning model spends most of it on
    /// its scratchpad before it writes any JSON, so this is generous.
    pub analyze_tokens: u32,
    /// Conversations per LLM call.
    pub batch: usize,
    /// Set when a reverse proxy already gates the whole service.
    pub open: bool,
}

fn var(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn home() -> PathBuf {
    PathBuf::from(var("HOME", "/var/lib/hermes"))
}

impl Config {
    pub fn from_env() -> Self {
        let h = home();
        Config {
            db: std::env::var("MNEMO_DB").ok().filter(|s| !s.is_empty()),
            sessions_db: PathBuf::from(var(
                "MNEMO_SESSIONS_DB",
                &h.join(".hermes/state.db").to_string_lossy(),
            )),
            llm_url: var("MNEMO_LLM_URL", "http://127.0.0.1:8094/v1"),
            llm_model: var("MNEMO_LLM_MODEL", "free-pool"),
            llm_key: std::env::var("MNEMO_LLM_KEY").ok().filter(|s| !s.is_empty()),
            llm_key_file: std::env::var("MNEMO_LLM_KEY_FILE")
                .ok()
                .filter(|s| !s.is_empty())
                .map(PathBuf::from),
            llm_zdr: var("MNEMO_LLM_ZDR", "0") == "1",
            hub_url: var("MNEMO_HUB_URL", "http://127.0.0.1:8095"),
            hub_token_file: PathBuf::from(var(
                "MNEMO_HUB_TOKEN_FILE",
                &h.join(".hermes/podcast-hub-token").to_string_lossy(),
            )),
            typer_dir: PathBuf::from(var("MNEMO_TYPER_DIR", "/var/lib/mnemo/typer-lang")),
            brief_dir: PathBuf::from(var(
                "MNEMO_BRIEF_DIR",
                &h.join(".hermes/mnemo/briefs").to_string_lossy(),
            )),
            bind: var("MNEMO_BIND", "127.0.0.1"),
            port: var("MNEMO_PORT", "9152").parse().unwrap_or(9152),
            token_file: PathBuf::from(var(
                "MNEMO_TOKEN_FILE",
                &h.join(".hermes/mnemo-token").to_string_lossy(),
            )),
            min_priority: var("MNEMO_MIN_PRIORITY", "8").parse().unwrap_or(8.0),
            brief_tokens: var("MNEMO_BRIEF_TOKENS", "6000").parse().unwrap_or(6000),
            analyze_tokens: var("MNEMO_ANALYZE_TOKENS", "8000").parse().unwrap_or(8000),
            batch: var("MNEMO_BATCH", "5").parse().unwrap_or(5),
            open: var("MNEMO_OPEN", "0") == "1",
        }
    }

    pub fn api_url(&self) -> String {
        format!("{}/chat/completions", self.llm_url.trim_end_matches('/'))
    }
}
