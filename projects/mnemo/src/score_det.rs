//! Deterministic scoring: rank a whole window of conversations with no model
//! call at all.
//!
//! The axes are the ones the podcast queue and the LLM pass already use
//! (matiere, points, ignorance, importance, focus) and `priorite` is the same
//! formula, so a deterministic row and a model-written row are comparable and
//! sort together in one table. Rows produced here carry `model = "det"`, which
//! is how the LLM pass knows it may overwrite them with something better.
//!
//! Everything is computed from the state database columns plus a keyword list:
//! scoring a thousand conversations costs nothing and takes seconds.

use crate::model::Score;
use crate::sessions::Meta;
use std::collections::HashSet;

/// Words that mean "Marc is out of his depth here": a question, a request for a
/// definition, a statement that he did not follow. Matched on folded text.
const CONFUSION: &[&str] = &[
    "c'est quoi",
    "qu'est-ce",
    "comment ca marche",
    "comment ca se",
    "pourquoi",
    "je comprends pas",
    "je comprend pas",
    "j'ai pas compris",
    "je sais pas",
    "je ne sais pas",
    "explique",
    "difference entre",
    "ca veut dire",
    "concretement",
    "je connais pas",
    "comment on fait",
    "how does",
    "what is",
    "i don't understand",
];

/// His life levers: the topics where knowing more changes a decision, which is
/// exactly what `importance` and `focus` are meant to capture. Weighted, and
/// matched on folded text.
const LEVERS: &[(&str, i32)] = &[
    ("visa", 4),
    ("titre de sejour", 4),
    ("green card", 4),
    ("impot", 4),
    ("fiscalite", 4),
    ("taxes", 3),
    ("salaire", 3),
    ("salary", 3),
    ("carriere", 3),
    ("career", 3),
    ("diplome", 3),
    ("ecole", 3),
    ("master", 2),
    ("embauche", 3),
    ("contrat", 2),
    ("loyer", 3),
    ("credit", 3),
    ("assurance", 2),
    ("mutuelle", 2),
    ("banque", 2),
    ("investissement", 3),
    ("bourse", 2),
    ("capital", 2),
    ("retraite", 3),
    ("cnam", 2),
    ("sante", 2),
    ("401k", 3),
    ("j-1", 3),
    ("j1", 3),
    ("h1b", 3),
];

/// Lowercase and strip the accents, so `impôt` and `impot` are the same word.
fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            'à' | 'â' | 'ä' | 'á' | 'À' | 'Â' | 'Ä' | 'Á' => out.push('a'),
            'é' | 'è' | 'ê' | 'ë' | 'É' | 'È' | 'Ê' | 'Ë' => out.push('e'),
            'î' | 'ï' | 'í' | 'Î' | 'Ï' | 'Í' => out.push('i'),
            'ô' | 'ö' | 'ó' | 'Ô' | 'Ö' | 'Ó' => out.push('o'),
            'û' | 'ü' | 'ù' | 'ú' | 'Û' | 'Ü' | 'Ù' | 'Ú' => out.push('u'),
            'ç' | 'Ç' => out.push('c'),
            'œ' | 'Œ' => out.push_str("oe"),
            '’' | '‘' => out.push('\''),
            c => out.extend(c.to_lowercase()),
        }
    }
    out
}

fn clip(s: &str, max: usize) -> String {
    let cleaned = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if cleaned.chars().count() <= max {
        cleaned
    } else {
        cleaned.chars().take(max).collect::<String>() + "…"
    }
}

/// Score one conversation from its metadata and Marc's own turns. No model.
pub fn score(meta: &Meta, text: &str) -> Score {
    let folded = fold(text);
    let words = text.split_whitespace().count();
    let per100 = |n: usize| n as f64 * 100.0 / (words.max(40) as f64);

    // matiere: how much concrete material his own turns carry, in a log-ish
    // ladder, plus what the tool activity around them shows was really done.
    let volume = match words {
        w if w < 40 => 0.5,
        w if w < 120 => 1.5,
        w if w < 300 => 3.0,
        w if w < 800 => 5.0,
        w if w < 2000 => 7.0,
        _ => 9.0,
    };
    let tools = (meta.tool_call_count as f64 / 25.0).min(2.5);
    let matiere = (volume + tools).round().clamp(0.0, 10.0) as i32;

    // ignorance: how lost he sounds. Density, not volume: a long technical
    // conversation where he follows along must not read as ignorance.
    let confusion = CONFUSION.iter().filter(|k| folded.contains(*k)).count();
    let questions = text.matches('?').count();
    let ignorance =
        (confusion as f64 * 1.5 + per100(questions) * 0.8).round().clamp(0.0, 10.0) as i32;

    // points: how many distinct things he asked about. Question or confusion
    // turns, deduplicated on their opening words so a repeated question counts
    // once.
    let mut seen = HashSet::new();
    let mut labels: Vec<String> = Vec::new();
    for sentence in text.split(|c: char| matches!(c, '?' | '\n' | '.' | '!' | ';')) {
        let s = sentence.trim();
        if s.chars().count() < 12 || s.starts_with('[') {
            continue;
        }
        let lower = fold(s);
        let asked = sentence.contains('?') || CONFUSION.iter().any(|k| lower.contains(*k));
        if !asked {
            continue;
        }
        let key: String = lower
            .split_whitespace()
            .take(6)
            .collect::<Vec<_>>()
            .join(" ");
        if seen.insert(key) {
            labels.push(clip(s, 60));
        }
    }
    let points = (labels.len() as f64 / 3.0).round().clamp(0.0, 10.0) as i32;

    // importance and focus: the levers, weighted and capped.
    let mut lever = 0i32;
    let mut domains: Vec<&str> = Vec::new();
    for (word, weight) in LEVERS {
        if folded.contains(*word) {
            lever += *weight;
            domains.push(*word);
        }
    }
    let focus = !domains.is_empty();
    let importance = (lever + if words > 400 { 1 } else { 0 }).clamp(0, 10);

    // sujet / objectif / domaine: the cheapest honest reading of the text.
    // Hermes already titles its sessions; that title beats a first line, and a
    // compacted conversation starts with a machine preamble that must never
    // show up as a subject.
    let sujet = if meta.title.trim().is_empty() {
        text.split('\n')
            .map(str::trim)
            .find(|l| l.chars().count() > 8 && !l.starts_with('['))
            .map(|l| clip(l, 90))
            .unwrap_or_default()
    } else {
        clip(meta.title.trim(), 90)
    };
    let objectif = labels.first().map(|l| clip(l, 120)).unwrap_or_default();
    let domaine = if domains.is_empty() {
        meta.source.clone()
    } else {
        domains
            .iter()
            .take(3)
            .copied()
            .collect::<Vec<_>>()
            .join(", ")
    };

    Score {
        id: meta.id.clone(),
        title: meta.title.clone(),
        source: meta.source.clone(),
        started_at: meta.started_at,
        sujet,
        objectif,
        domaine: domaine.chars().take(40).collect(),
        matiere,
        points,
        ignorance,
        importance,
        focus,
        points_liste: labels.iter().take(6).cloned().collect::<Vec<_>>().join(" | "),
        priorite: crate::analyze::priority(matiere, points, importance, focus),
        gaps: Vec::new(),
        terms: Vec::new(),
        model: "det".to_string(),
    }
}

/// The axes and the formula, for the site and for whoever tunes the weights.
pub fn explain() -> serde_json::Value {
    serde_json::json!({
        "model": "det",
        "ai": "none: this pass never calls a model",
        "formula": "priorite = importance + matiere/2 + points/2 + 4 if focus",
        "matiere": "his own word count (ladder 0.5/1.5/3/5/7/9) + tool calls / 25, capped at 2.5",
        "ignorance": "1.5 per confusion keyword + 0.8 per question per 100 words, capped at 10",
        "points": "distinct question or confusion turns, deduplicated on their opening words, / 3",
        "importance": "sum of the life-lever weights (visa, impot, salaire, carriere, ecole, credit...), capped at 10",
        "focus": "true as soon as one life lever appears",
        "confusion_keywords": CONFUSION,
        "levers": LEVERS.iter().map(|(w, n)| format!("{w}:{n}")).collect::<Vec<_>>(),
    })
}
