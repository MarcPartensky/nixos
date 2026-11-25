//! Persistence. Postgres when `MNEMO_DB` is set, otherwise a no-op store so
//! the whole engine can be exercised on the laptop without a database.

use crate::model::{Brief, Score};
use crate::R;
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio_postgres::types::ToSql;
use tokio_postgres::{Client, NoTls};

pub enum Store {
    Pg(Pg),
    Dry,
}

impl Store {
    pub async fn open(db: Option<&str>) -> R<Store> {
        match db {
            Some(url) => Ok(Store::Pg(Pg::connect(url).await?)),
            None => Ok(Store::Dry),
        }
    }

    pub async fn migrate(&self) -> R<()> {
        if let Store::Pg(pg) = self {
            pg.exec_raw(include_str!("../sql/schema.sql")).await?;
        }
        Ok(())
    }

    pub async fn put_score(&self, score: &Score) -> R<()> {
        let Store::Pg(pg) = self else { return Ok(()) };
        pg.execute(
            "insert into session_score (id, source, title, started_at, sujet, objectif, domaine, \
             matiere, points, ignorance, importance, focus, points_liste, priorite, model, scored_at) \
             values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15, extract(epoch from now())) \
             on conflict (id) do update set source=excluded.source, title=excluded.title, \
             sujet=excluded.sujet, objectif=excluded.objectif, domaine=excluded.domaine, \
             matiere=excluded.matiere, points=excluded.points, ignorance=excluded.ignorance, \
             importance=excluded.importance, focus=excluded.focus, \
             points_liste=excluded.points_liste, priorite=excluded.priorite, \
             model=excluded.model, scored_at=extract(epoch from now())",
            &[
                &score.id,
                &score.source,
                &score.title,
                &score.started_at,
                &score.sujet,
                &score.objectif,
                &score.domaine,
                &score.matiere,
                &score.points,
                &score.ignorance,
                &score.importance,
                &score.focus,
                &score.points_liste,
                &score.priorite,
                &score.model,
            ],
        )
        .await?;

        for gap in &score.gaps {
            pg.execute(
                "insert into gap (session_id, point, quote, explanation) values ($1,$2,$3,$4) \
                 on conflict (session_id, point) do update set quote=excluded.quote, \
                 explanation=excluded.explanation",
                &[&score.id, &gap.point, &gap.quote, &gap.to_explain],
            )
            .await?;
        }
        Ok(())
    }

    pub async fn put_brief(&self, brief: &Brief) -> R<()> {
        let Store::Pg(pg) = self else { return Ok(()) };
        pg.execute(
            "insert into brief (session_id, title, summary, body, reading_minutes, terms, written_at) \
             values ($1,$2,$3,$4,$5,$6, extract(epoch from now())) \
             on conflict (session_id) do update set title=excluded.title, summary=excluded.summary, \
             body=excluded.body, reading_minutes=excluded.reading_minutes, terms=excluded.terms, \
             written_at=extract(epoch from now())",
            &[
                &brief.session_id,
                &brief.title,
                &brief.summary,
                &brief.body,
                &brief.reading_minutes,
                &brief.terms,
            ],
        )
        .await?;
        Ok(())
    }

    pub async fn mark_published(&self, session_id: &str, channel: &str, reference: &str) -> R<()> {
        let Store::Pg(pg) = self else { return Ok(()) };
        pg.execute(
            "insert into publish (session_id, channel, reference) values ($1,$2,$3) \
             on conflict (session_id, channel) do update set reference=excluded.reference, \
             at=extract(epoch from now())",
            &[&session_id, &channel, &reference],
        )
        .await?;
        Ok(())
    }

    pub async fn already_published(&self, session_id: &str, channel: &str) -> R<bool> {
        let Store::Pg(pg) = self else { return Ok(false) };
        let rows = pg
            .query(
                "select 1 from publish where session_id=$1 and channel=$2",
                &[&session_id, &channel],
            )
            .await?;
        Ok(!rows.is_empty())
    }

    /// Backlog ordered by priority, with the brief attached when one exists.
    pub async fn backlog(&self, min_priority: f64, limit: i64) -> R<Vec<serde_json::Value>> {
        let Store::Pg(pg) = self else {
            return Ok(Vec::new());
        };
        let rows = pg
            .query(
                "select s.id, s.title, s.sujet, s.objectif, s.domaine, s.matiere, s.points, \
                 s.importance, s.focus, s.priorite, s.points_liste, s.started_at, \
                 b.title as brief_title, b.summary, b.reading_minutes \
                 from session_score s left join brief b on b.session_id = s.id \
                 where s.priorite >= $1 order by s.priorite desc, s.started_at desc limit $2",
                &[&min_priority, &limit],
            )
            .await?;
        Ok(rows
            .iter()
            .map(|row| {
                serde_json::json!({
                    "id": row.get::<_, String>(0),
                    "title": row.get::<_, Option<String>>(1),
                    "sujet": row.get::<_, Option<String>>(2),
                    "objectif": row.get::<_, Option<String>>(3),
                    "domaine": row.get::<_, Option<String>>(4),
                    "matiere": row.get::<_, Option<i32>>(5),
                    "points": row.get::<_, Option<i32>>(6),
                    "importance": row.get::<_, Option<i32>>(7),
                    "focus": row.get::<_, Option<bool>>(8),
                    "priorite": row.get::<_, Option<f64>>(9),
                    "points_liste": row.get::<_, Option<String>>(10),
                    "started_at": row.get::<_, Option<f64>>(11),
                    "brief_title": row.get::<_, Option<String>>(12),
                    "summary": row.get::<_, Option<String>>(13),
                    "reading_minutes": row.get::<_, Option<i32>>(14),
                    "has_brief": row.get::<_, Option<String>>(12).is_some(),
                })
            })
            .collect())
    }

    pub async fn brief(&self, session_id: &str) -> R<Option<serde_json::Value>> {
        let Store::Pg(pg) = self else { return Ok(None) };
        let rows = pg
            .query(
                "select b.title, b.summary, b.body, b.reading_minutes, b.terms, s.sujet, s.objectif, \
                 s.priorite from brief b join session_score s on s.id = b.session_id where b.session_id=$1",
                &[&session_id],
            )
            .await?;
        Ok(rows.first().map(|row| {
            serde_json::json!({
                "session_id": session_id,
                "title": row.get::<_, Option<String>>(0),
                "summary": row.get::<_, Option<String>>(1),
                "body": row.get::<_, Option<String>>(2),
                "reading_minutes": row.get::<_, Option<i32>>(3),
                "terms": row.get::<_, Option<Vec<String>>>(4),
                "sujet": row.get::<_, Option<String>>(5),
                "objectif": row.get::<_, Option<String>>(6),
                "priorite": row.get::<_, Option<f64>>(7),
            })
        }))
    }

    pub async fn gaps(&self, session_id: &str) -> R<Vec<serde_json::Value>> {
        let Store::Pg(pg) = self else {
            return Ok(Vec::new());
        };
        let rows = pg
            .query(
                "select point, quote, explanation from gap where session_id=$1 order by id",
                &[&session_id],
            )
            .await?;
        Ok(rows
            .iter()
            .map(|row| {
                serde_json::json!({
                    "point": row.get::<_, String>(0),
                    "quote": row.get::<_, Option<String>>(1),
                    "explanation": row.get::<_, Option<String>>(2),
                })
            })
            .collect())
    }

    pub async fn stats(&self) -> R<serde_json::Value> {
        let Store::Pg(pg) = self else {
            return Ok(serde_json::json!({"dry_run": true}));
        };
        let rows = pg
            .query(
                "select (select count(*) from session_score), (select count(*) from gap), \
                 (select count(*) from brief), \
                 (select count(*) from session_score where priorite >= 8), \
                 (select count(*) from publish)",
                &[],
            )
            .await?;
        let row = &rows[0];
        Ok(serde_json::json!({
            "scored": row.get::<_, i64>(0),
            "gaps": row.get::<_, i64>(1),
            "briefs": row.get::<_, i64>(2),
            "important": row.get::<_, i64>(3),
            "published": row.get::<_, i64>(4),
        }))
    }

    /// Every term Marc did not understand, most frequent first: the raw
    /// material for the typing drill.
    pub async fn terms(&self) -> R<Vec<(String, i64)>> {
        let Store::Pg(pg) = self else { return Ok(Vec::new()) };
        let rows = pg
            .query(
                "select t.term, count(*) as n from brief b, unnest(b.terms) as t(term) \
                 where length(t.term) between 3 and 24 group by t.term order by n desc, t.term",
                &[],
            )
            .await?;
        Ok(rows
            .iter()
            .map(|row| (row.get::<_, String>(0), row.get::<_, i64>(1)))
            .collect())
    }
}

pub struct Pg {
    url: String,
    client: Arc<Mutex<Option<Client>>>,
}

impl Pg {
    async fn connect(url: &str) -> R<Self> {
        let pg = Pg {
            url: url.to_string(),
            client: Arc::new(Mutex::new(None)),
        };
        pg.ensure().await?;
        Ok(pg)
    }

    async fn ensure(&self) -> R<()> {
        let mut guard = self.client.lock().await;
        if guard.is_none() {
            let (client, connection) = tokio_postgres::connect(&self.url, NoTls).await?;
            let slot = Arc::clone(&self.client);
            tokio::spawn(async move {
                match connection.await {
                    Ok(()) => eprintln!("[mnemo] postgres connection closed by the server"),
                    Err(err) => eprintln!("[mnemo] postgres connection ended: {err}"),
                }
                // A corpse must not stay in the slot: Postgres restarts at every
                // NixOS switch, and without this the app answers "connection
                // closed" to every query until the process is restarted.
                *slot.lock().await = None;
            });
            *guard = Some(client);
        }
        Ok(())
    }

    async fn handle(&self) -> R<Client> {
        self.ensure().await?;
        let guard = self.client.lock().await;
        match guard.as_ref() {
            Some(client) => Ok(client.clone()),
            None => Err("postgres client unavailable".into()),
        }
    }

    async fn drop_handle(&self) {
        *self.client.lock().await = None;
    }

    async fn exec_raw(&self, sql: &str) -> R<()> {
        let client = self.handle().await?;
        if client.batch_execute(sql).await.is_err() {
            self.drop_handle().await;
            let client = self.handle().await?;
            client.batch_execute(sql).await?;
        }
        Ok(())
    }

    async fn execute(&self, sql: &str, params: &[&(dyn ToSql + Sync)]) -> R<u64> {
        let client = self.handle().await?;
        match client.execute(sql, params).await {
            Ok(n) => Ok(n),
            // Likely a handle left dead by a Postgres restart: drop it and try
            // once on a fresh connection instead of failing the request.
            Err(_) => {
                self.drop_handle().await;
                let client = self.handle().await?;
                Ok(client.execute(sql, params).await?)
            }
        }
    }

    async fn query(&self, sql: &str, params: &[&(dyn ToSql + Sync)]) -> R<Vec<tokio_postgres::Row>> {
        let client = self.handle().await?;
        match client.query(sql, params).await {
            Ok(rows) => Ok(rows),
            Err(_) => {
                self.drop_handle().await;
                let client = self.handle().await?;
                Ok(client.query(sql, params).await?)
            }
        }
    }
}
