//! One pass of the engine: read the new conversations, score them, write the
//! briefs for the ones that matter, optionally hand them to the podcast
//! pipeline. Shared by the CLI and the HTTP/MCP entry points.

use crate::analyze;
use crate::http::App;
use crate::model::Score;
use crate::R;
use serde_json::{json, Value};

pub async fn run(
    app: &App,
    since: f64,
    limit: usize,
    briefs: bool,
    publish: bool,
) -> R<Value> {
    let sessions = crate::sessions::load(&app.cfg, since, limit)?;
    let mut scored: Vec<Score> = Vec::new();
    for chunk in sessions.chunks(app.cfg.batch.max(1)) {
        let mut batch = analyze::analyze(&app.llm, chunk, app.cfg.analyze_tokens).await?;
        scored.append(&mut batch);
    }
    scored.sort_by(|a, b| {
        b.priorite
            .partial_cmp(&a.priorite)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let mut briefed = Vec::new();
    let mut published = Vec::new();
    for score in &scored {
        app.store.put_score(score).await?;
        if !briefs || score.priorite < app.cfg.min_priority {
            continue;
        }
        if app.store.brief(&score.id).await?.is_some() {
            continue;
        }
        let Some(session) = crate::sessions::load_one(&app.cfg, &score.id)? else {
            continue;
        };
        let brief = analyze::write_brief(&app.llm, score, &session, app.cfg.brief_tokens).await?;
        app.store.put_brief(&brief).await?;
        if let Err(err) = crate::publish::brief_file(&app.cfg, &brief) {
            eprintln!("[mnemo] could not mirror the sheet to disk: {err}");
        }
        if publish && !app.store.already_published(&score.id, "podcast").await? {
            let reference = crate::publish::to_podcast(&app.cfg, score, Some(&brief)).await?;
            app.store
                .mark_published(&score.id, "podcast", &reference)
                .await?;
            published.push(reference);
        }
        briefed.push(json!({
            "id": brief.session_id, "title": brief.title,
            "reading_minutes": brief.reading_minutes, "priorite": score.priorite,
        }));
    }

    Ok(json!({
        "scanned": sessions.len(),
        "scored": scored.len(),
        "briefs": briefed,
        "published": published,
        "top": scored.iter().take(10).map(|s| json!({
            "id": s.id, "sujet": s.sujet, "domaine": s.domaine,
            "matiere": s.matiere, "points": s.points, "importance": s.importance,
            "focus": s.focus, "priorite": s.priorite, "gaps": s.gaps.len(),
            "points_liste": s.points_liste,
        })).collect::<Vec<_>>(),
    }))
}
