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
                if summary_text.len() < MAX_USER_CHARS {
                    let room = MAX_USER_CHARS - summary_text.len();
                    summary_text.push_str(&text[..text.len().min(room)]);
                    summary_text.push('\n');
                }
            } else if !is_injected(text) {
                if user_text.len() < MAX_USER_CHARS {
                    let room = MAX_USER_CHARS - user_text.len();
                    let chunk = &text[..text.len().min(room)];
                    user_text.push_str(chunk);
                    user_text.push('\n');
                }
            } else {
                continue;
            }
        }
        if transcript.len() >= MAX_SOURCE_CHARS {
            break;
        }
        let trimmed = &text[..text.len().min(MAX_TURN_CHARS)];
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
