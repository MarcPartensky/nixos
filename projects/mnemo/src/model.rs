//! The data the engine moves around: a conversation, its score, its gaps and
//! the brief written from them.

use serde::{Deserialize, Serialize};

/// One conversation, reduced to what the model needs to see.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub source: String,
    pub title: String,
    pub started_at: f64,
    /// Marc's own turns, concatenated (bounded).
    pub user_text: String,
    /// The whole conversation, bounded, for the brief writer.
    pub transcript: String,
    pub words: usize,
    /// True when the raw turns were compacted and `user_text` is the summary.
    #[serde(default)]
    pub compacted: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Gap {
    pub point: String,
    #[serde(default)]
    pub quote: String,
    #[serde(default)]
    pub to_explain: String,
}

/// The three-axis reading of a conversation, plus the extracted gaps.
///
/// The axes are the ones already used by the podcast queue (matiere, points,
/// importance, focus); `priorite` is the single number the engine sorts on.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Score {
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub started_at: f64,
    #[serde(default)]
    pub sujet: String,
    #[serde(default)]
    pub objectif: String,
    #[serde(default)]
    pub domaine: String,
    #[serde(default)]
    pub matiere: i32,
    #[serde(default)]
    pub points: i32,
    #[serde(default)]
    pub ignorance: i32,
    #[serde(default)]
    pub importance: i32,
    #[serde(default)]
    pub focus: bool,
    #[serde(default)]
    pub points_liste: String,
    #[serde(default)]
    pub priorite: f64,
    #[serde(default)]
    pub gaps: Vec<Gap>,
    #[serde(default)]
    pub terms: Vec<String>,
    #[serde(default)]
    pub model: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Brief {
    pub session_id: String,
    pub title: String,
    pub summary: String,
    /// Markdown: the explanation sheet that doubles as a podcast source.
    pub body: String,
    pub reading_minutes: i32,
    #[serde(default)]
    pub terms: Vec<String>,
}
