//! Reading Marc's conversations out of the Hermes state database.
//!
//! The database is opened READ-ONLY: mnemo is a reader of the history, it never
//! writes into it. The same bounding rules as the podcast hub are applied, so a
//! scored conversation and a podcast source describe the same text.

use crate::config::Config;
use crate::model::Session;
use crate::R;
use rusqlite::{Connection, OpenFlags};

/// Messages that are not Marc speaking: injected context, cron output, tool
/// results. They are dropped from the score input.
const INJECTED: &[&str] = &[
    "[IMPORTANT",
    "[Cron deliv",
    "[OUT-OF-BAND",
    "[System:",
    "[System n",
    "[Backgrou",
    "[ASYNC DE",
    "[CONTEXT",
    "[Error",
    "[Tool",
    "[Reminder",
];

/// When a conversation grew past its window, Hermes replaces the early turns
/// with a summary injected as a user message. That summary is the only trace
/// left of an old discussion, so it is scored as a proxy rather than skipped:
/// "scan all my conversations" has to mean all of them.
const COMPACTED: &str = "[CONTEXT COMPACTION";

const MAX_USER_CHARS: usize = 6000;
const MAX_SOURCE_CHARS: usize = 60000;
const MAX_TURN_CHARS: usize = 6000;

/// Truncate on a character boundary. Slicing a `&str` by byte index panics when
/// the cut lands inside a multi-byte character, and Marc writes French: an
/// accent at the wrong offset would take the whole engine down.
fn take_chars(s: &str, max_chars: usize) -> &str {
    match s.char_indices().nth(max_chars) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

fn open(cfg: &Config) -> R<Connection> {
    let conn = Connection::open_with_flags(
        &cfg.sessions_db,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    Ok(conn)
}

fn is_injected(text: &str) -> bool {
    INJECTED.iter().any(|p| text.starts_with(p))
}

/// Read every conversation started after `since`, oldest first.
pub fn load(cfg: &Config, since: f64, limit: usize) -> R<Vec<Session>> {
    let conn = open(cfg)?;
    let mut stmt = conn.prepare(
        "select id, source, title, started_at from sessions \
         where source not in ('cron','subagent','oneshot') and started_at > ? \
         order by started_at asc limit ?",
    )?;
    let rows = stmt
        .query_map(rusqlite::params![since, limit as i64], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                row.get::<_, f64>(3)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;

    let mut out = Vec::new();
    for (id, source, title, started_at) in rows {
        if let Some(session) = build(&conn, &id, &source, &title, started_at)? {
            out.push(session);
        }
    }
    Ok(out)
}

/// One conversation's metadata, without its messages. Enough for the
/// deterministic pass, which reads the text one conversation at a time and
/// never needs the whole window in memory.
pub struct Meta {
    pub id: String,
    pub source: String,
    pub title: String,
    pub started_at: f64,
    pub message_count: i64,
    pub tool_call_count: i64,
    pub tokens: i64,
    pub cwd: String,
    pub model: String,
}

/// Every conversation started after `since`, oldest first, metadata only.
/// `limit = 0` means no limit; `offset` pages through the window.
pub fn metas(cfg: &Config, since: f64, limit: usize, offset: usize) -> R<Vec<Meta>> {
    let conn = open(cfg)?;
    let mut stmt = conn.prepare(
        "select id, source, title, started_at, message_count, tool_call_count, \
         coalesce(input_tokens,0) + coalesce(output_tokens,0), coalesce(cwd,''), \
         coalesce(model,'') from sessions \
         where source not in ('cron','subagent','oneshot') and started_at > ? \
         order by started_at asc limit ? offset ?",
    )?;
    let lim = if limit == 0 { -1i64 } else { limit as i64 };
    let rows = stmt
        .query_map(rusqlite::params![since, lim, offset as i64], |row| {
            Ok(Meta {
                id: row.get(0)?,
                source: row.get(1)?,
                title: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                started_at: row.get(3)?,
                message_count: row.get::<_, Option<i64>>(4)?.unwrap_or(0),
                tool_call_count: row.get::<_, Option<i64>>(5)?.unwrap_or(0),
                tokens: row.get::<_, Option<i64>>(6)?.unwrap_or(0),
                cwd: row.get(7)?,
                model: row.get(8)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Marc's own turns of one conversation, bounded and with the injected context
/// dropped: the text the deterministic scorer reads. Same rules as `build`, so
/// both passes describe the same words.
pub fn his_words(cfg: &Config, id: &str) -> R<String> {
    let conn = open(cfg)?;
    let mut stmt = conn.prepare(
        "select content from messages where session_id = ? and role = 'user' \
         and active = 1 order by id",
    )?;
    let msgs = stmt
        .query_map(rusqlite::params![id], |row| {
            Ok(row.get::<_, Option<String>>(0)?.unwrap_or_default())
        })?
        .collect::<Result<Vec<_>, _>>()?;

    let mut user_text = String::new();
    let mut summary_text = String::new();
    for content in &msgs {
        let text = content.trim();
        if text.is_empty() {
            continue;
        }
        if text.starts_with(COMPACTED) {
            let room = MAX_USER_CHARS.saturating_sub(summary_text.chars().count());
            if room > 0 {
                summary_text.push_str(take_chars(text, room));
                summary_text.push('\n');
            }
        } else if !is_injected(text) {
            let room = MAX_USER_CHARS.saturating_sub(user_text.chars().count());
            if room > 0 {
                user_text.push_str(take_chars(text, room));
                user_text.push('\n');
            }
        }
    }
    if user_text.trim().is_empty() {
        user_text = summary_text;
    }
    Ok(user_text.trim().to_string())
}

pub fn load_one(cfg: &Config, id: &str) -> R<Option<Session>> {
    let conn = open(cfg)?;
    let row = conn
        .query_row(
            "select id, source, title, started_at from sessions where id = ?",
            rusqlite::params![id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    row.get::<_, f64>(3)?,
                ))
            },
        )
        .ok();
    match row {
        None => Ok(None),
        Some((id, source, title, started_at)) => build(&conn, &id, &source, &title, started_at),
    }
}

fn build(
    conn: &Connection,
    id: &str,
    source: &str,
    title: &str,
    started_at: f64,
) -> R<Option<Session>> {
    let mut stmt = conn.prepare(
        "select role, content from messages \
         where session_id = ? and role in ('user','assistant') and active = 1 order by id",
    )?;
    let msgs = stmt
        .query_map(rusqlite::params![id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?.unwrap_or_default(),
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;

    let mut user_text = String::new();
    let mut summary_text = String::new();
    let mut transcript = String::new();
    let mut words = 0usize;

    for (role, content) in &msgs {
        let text = content.trim();
        if text.is_empty() {
            continue;
        }
        if role == "user" {
            if text.starts_with(COMPACTED) {
                let room = MAX_USER_CHARS.saturating_sub(summary_text.chars().count());
                if room > 0 {
                    summary_text.push_str(take_chars(text, room));
                    summary_text.push('\n');
                }
            } else if !is_injected(text) {
                let room = MAX_USER_CHARS.saturating_sub(user_text.chars().count());
                if room > 0 {
                    user_text.push_str(take_chars(text, room));
                    user_text.push('\n');
                }
            } else {
                continue;
            }
        }
        if transcript.len() >= MAX_SOURCE_CHARS {
            break;
        }
        let trimmed = take_chars(text, MAX_TURN_CHARS);
        let label = if role == "user" {
            if text.starts_with(COMPACTED) {
                "RESUME DE LA CONVERSATION"
            } else {
                "MARC"
            }
        } else {
            "ASSISTANT"
        };
        transcript.push_str(label);
        transcript.push_str(": ");
        transcript.push_str(trimmed);
        transcript.push_str("\n\n");
        words += trimmed.split_whitespace().count();
    }

    // Nothing Marc said survived, but the conversation is still described by
    // its summary: score that, flagged so the model knows what it is reading.
    let compacted = user_text.trim().is_empty() && !summary_text.trim().is_empty();
    if compacted {
        user_text = summary_text.clone();
    }
    if user_text.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some(Session {
        id: id.to_string(),
        source: source.to_string(),
        title: title.to_string(),
        started_at,
        user_text: user_text.trim().to_string(),
        transcript: transcript.trim().to_string(),
        words,
        compacted,
    }))
}

/// A compact digest of one conversation, used as the LLM input.
pub fn digest(session: &Session) -> String {
    let title = if session.title.is_empty() {
        "(untitled)"
    } else {
        &session.title
    };
    format!(
        "title: {}\nwords: {}\n{}\n{}",
        title,
        session.words,
        if session.compacted {
            "note: this conversation was compacted, you are reading its summary"
        } else {
            "note: raw turns"
        },
        session.user_text
    )
}
