//! The two model calls that make this engine worth running: score a
//! conversation (and list what Marc did not understand), then write the
//! explanation sheet that doubles as a podcast source.

use crate::llm::Llm;
use crate::model::{Brief, Gap, Score, Session};
use crate::R;
use serde_json::Value;

/// The scoring grid already used by the podcast queue, extended with the gap
/// extraction: same axes, so both pipelines agree on what "important" means.
pub const ANALYZE_SYSTEM: &str = r#"Tu analyses des conversations entre Marc (francais) et un assistant.
Pour CHAQUE conversation numerotee, rends un objet avec ces champs :

- "matiere" (0-10) : quantite de matiere concrete disponible pour en faire un episode. 0 = question seche sans suite ; 10 = plusieurs questions, des chiffres, des cas reels, des desaccords, des relances.
- "ignorance" (0-10) : a quel point Marc ne connait pas le domaine. 0 = il maitrise et discute de details pointus ; 10 = il decouvre, questions de base, vocabulaire absent, il repete la meme question.
- "points" (0-10, entier) : COMBIEN de points distincts Marc n'a pas compris et qu'il faudrait lui expliquer. C'est un compte, pas une intensite : 0 = aucun trou, 1 = un point isole, 3 = trois notions a reprendre, 6+ = la conversation est un chantier.
- "points_liste" : ces points, un libelle de 3 a 6 mots chacun, separes par " | ".
- "importance" (0-10) : combien il est important que Marc le sache pour avancer dans sa vie. 0 = anecdote ; 5 = culture utile ; 8 = decision de carriere, de diplome ou d'argent ; 10 = ca change une trajectoire (visa, contrat, fiscalite, ecole, choix de metier).
- "focus" (true/false) : le sujet touche diplomes, ecoles, etudes, carrieres, emploi, salaire, argent, capital, finance ou investissement.
- "domaine" : 1 a 3 mots.
- "sujet" : le sujet en une phrase courte.
- "objectif" : ce que Marc cherchait a comprendre, en une phrase.
- "gaps" : les points non compris, tableau d'objets {"point": "libelle court", "quote": "citation exacte de Marc, tiree du texte", "to_explain": "ce qu'il faut expliquer, 2 a 4 phrases, avec un chiffre ou un exemple quand c'est possible"}.
- "terms" : 3 a 8 mots techniques ou notions que Marc devrait savoir ecrire et reconnaitre.

Signaux d'incomprehension a chercher : une question posee deux fois, un "ok" apres une explication longue, une objection non traitee, un changement de sujet juste apres un point dense, une question de definition.

Reponds en JSON strict : {"items":[{"n":1, ...}]} ou "n" est le numero de la conversation. Aucun texte hors du JSON."#;

/// The retention template from the podcast work: the sheet must stand alone.
pub const BRIEF_SYSTEM: &str = r#"Tu ecris une fiche de retention en francais pour Marc, a partir d'une conversation et de la liste de ses points non compris.

Commence par une ligne "TITRE: <titre court et precis>" puis un corps en Markdown, avec ces titres exacts et dans cet ordre :

## Sa question d'origine
## Ce qu'il croyait
## Le modele correct
(avec une analogie concrete)
## Un chiffre verifie
## A retenir en une phrase
## Auto-test
(une seule question, sans la reponse)

Regles : francais simple, aucun tiret cadratin, chiffres concrets quand la conversation en contient, aucune flatterie, 350 a 600 mots. La fiche doit tenir seule, sans avoir lu la conversation : elle servira de source a un podcast et de page sur son site. N'invente aucun chiffre qui ne soit pas dans la conversation ou verifiable ; si un chiffre manque, dis ce qu'il faudrait mesurer."#;

/// `importance + matiere/2 + points/2`, plus a bonus when the topic is one of
/// Marc's life levers. Identical to the podcast queue formula.
pub fn priority(matiere: i32, points: i32, importance: i32, focus: bool) -> f64 {
    importance as f64 + matiere as f64 / 2.0 + points as f64 / 2.0 + if focus { 4.0 } else { 0.0 }
}

fn clamp(v: &Value, max: i32) -> i32 {
    v.as_i64()
        .or_else(|| v.as_f64().map(|f| f as i64))
        .unwrap_or(0)
        .clamp(0, max as i64) as i32
}

fn text(v: &Value) -> String {
    v.as_str().unwrap_or_default().trim().to_string()
}

fn to_score(item: &Value, session: &Session, model: &str) -> Score {
    let matiere = clamp(&item["matiere"], 10);
    let points = clamp(&item["points"], 10);
    let importance = clamp(&item["importance"], 10);
    let focus = item["focus"].as_bool().unwrap_or(false);
    let gaps = item["gaps"]
        .as_array()
        .map(|list| {
            list.iter()
                .filter_map(|g| {
                    let point = text(&g["point"]);
                    if point.is_empty() {
                        return None;
                    }
                    Some(Gap {
                        point,
                        quote: text(&g["quote"]),
                        to_explain: text(&g["to_explain"]),
                    })
                })
                .take(8)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let terms = item["terms"]
        .as_array()
        .map(|list| {
            list.iter()
                .map(|t| text(t))
                .filter(|t| !t.is_empty())
                .take(8)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    Score {
        id: session.id.clone(),
        title: session.title.clone(),
        source: session.source.clone(),
        started_at: session.started_at,
        sujet: text(&item["sujet"]),
        objectif: text(&item["objectif"]),
        domaine: text(&item["domaine"]).chars().take(40).collect(),
        matiere,
        points,
        ignorance: clamp(&item["ignorance"], 10),
        importance,
        focus,
        points_liste: text(&item["points_liste"]).chars().take(300).collect(),
        priorite: priority(matiere, points, importance, focus),
        gaps,
        terms,
        model: model.to_string(),
    }
}

/// Score a batch of conversations in one call. A batch whose JSON comes back
/// truncated is split in two rather than dropped: silent loss is the failure
/// mode that hurts, because the queue just looks empty.
pub async fn analyze(llm: &Llm, batch: &[Session], max_tokens: u32) -> R<Vec<Score>> {
    if batch.is_empty() {
        return Ok(Vec::new());
    }
    let mut user = String::new();
    for (i, session) in batch.iter().enumerate() {
        user.push_str(&format!("--- conversation {} ---\n", i + 1));
        user.push_str(&crate::sessions::digest(session));
        user.push_str("\n\n");
    }
    let result = llm.chat_json(ANALYZE_SYSTEM, &user, max_tokens).await;
    match result {
        Ok((value, model)) => {
            let items = value["items"].as_array().cloned().unwrap_or_default();
            let mut out = Vec::new();
            for item in &items {
                let n = item["n"].as_i64().unwrap_or(0);
                let idx = if n >= 1 { (n - 1) as usize } else { 0 };
                if let Some(session) = batch.get(idx) {
                    out.push(to_score(item, session, &model));
                }
            }
            if out.is_empty() {
                return Err("the model returned no usable item".into());
            }
            Ok(out)
        }
        Err(err) => {
            if batch.len() == 1 {
                return Err(err);
            }
            let mid = batch.len() / 2;
            eprintln!("[mnemo] batch of {} failed ({}), splitting", batch.len(), err);
            let mut left = Box::pin(analyze(llm, &batch[..mid], max_tokens)).await?;
            let mut right = Box::pin(analyze(llm, &batch[mid..], max_tokens)).await?;
            left.append(&mut right);
            Ok(left)
        }
    }
}

/// Write the explanation sheet for one scored conversation.
pub async fn write_brief(
    llm: &Llm,
    score: &Score,
    session: &Session,
    max_tokens: u32,
) -> R<Brief> {
    let mut gaps = String::new();
    for (i, gap) in score.gaps.iter().enumerate() {
        gaps.push_str(&format!(
            "{}. {} -- ce qu'il n'a pas compris : {}\n",
            i + 1,
            gap.point,
            if gap.to_explain.is_empty() {
                "(a expliquer)"
            } else {
                &gap.to_explain
            }
        ));
    }
    let transcript: String = session.transcript.chars().take(14000).collect();
    let base = format!(
        "Sujet : {}\nCe qu'il cherchait : {}\nPoints non compris :\n{}\n\n--- conversation ---\n{}",
        score.sujet, score.objectif, gaps, transcript
    );

    // A free model sometimes stops after two sentences. The sheet is worthless
    // half-written, so one explicit retry, then keep whatever came back.
    let mut answer = String::new();
    for attempt in 0..2 {
        let user = if attempt == 0 {
            base.clone()
        } else {
            format!(
                "{base}\n\nTa reponse precedente s'est arretee trop tot. Ecris la fiche ENTIERE, \
                 400 a 600 mots, et va jusqu'a la section ## Auto-test incluse."
            )
        };
        let (text, _model) = llm.chat(BRIEF_SYSTEM, &user, max_tokens).await?;
        answer = text;
        if answer.len() >= 900 {
            break;
        }
        eprintln!(
            "[mnemo] short sheet ({} chars), retrying once",
            answer.len()
        );
    }

    let mut title = score.sujet.clone();
    let mut body = answer.clone();
    if let Some(rest) = answer.strip_prefix("TITRE:") {
        let mut lines = rest.splitn(2, '\n');
        let first = lines.next().unwrap_or_default().trim().to_string();
        if !first.is_empty() {
            title = first;
        }
        body = lines.next().unwrap_or_default().trim().to_string();
    }
    let words = body.split_whitespace().count();
    Ok(Brief {
        session_id: score.id.clone(),
        title,
        summary: summarize(&body),
        body,
        reading_minutes: ((words as f64 / 180.0).ceil() as i32).max(1),
        terms: score.terms.clone(),
    })
}

/// First paragraph that is not a heading, bounded: the one-line answer to
/// "why should I read this".
fn summarize(body: &str) -> String {
    for block in body.split("\n\n") {
        let line = block.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let flat = line.replace('\n', " ");
        return flat.chars().take(400).collect();
    }
    body.chars().take(400).collect()
}
