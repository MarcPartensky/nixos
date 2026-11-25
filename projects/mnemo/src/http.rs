//! HTTP surface: the JSON API the site and the agent use, plus an MCP endpoint
//! so Hermes can call the engine as a tool.
//!
//! Browser traffic arrives through Pangolin (TLS + Zitadel SSO) and needs no
//! token; everything under /api and /mcp additionally accepts `X-Mnemo-Token`
//! for machine clients that cannot follow a redirect. When the service is
//! published behind the proxy the token is the only gate, so it is generated on
//! first start and never logged.

use crate::config::Config;
use crate::llm::Llm;
use crate::store::Store;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;

pub struct App {
    pub cfg: Config,
    pub llm: Llm,
    pub store: Store,
    pub token: String,
}

pub fn router(app: Arc<App>) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/", get(index))
        .route("/api/stats", get(api_stats))
        .route("/api/backlog", get(api_backlog))
        .route("/api/brief", get(api_brief))
        .route("/api/gaps", get(api_gaps))
        .route("/api/wordlist", get(api_wordlist))
        .route("/api/scan", post(api_scan))
        .route("/mcp", post(mcp).get(mcp_get))
        .with_state(app)
}

fn token_of(headers: &HeaderMap) -> Option<String> {
    if let Some(v) = headers.get("x-mnemo-token").and_then(|v| v.to_str().ok()) {
        return Some(v.to_string());
    }
    headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .map(|v| v.trim_start_matches("Bearer ").trim().to_string())
}

fn allowed(app: &App, headers: &HeaderMap) -> bool {
    if app.cfg.open {
        return true;
    }
    token_of(headers).map(|t| t == app.token).unwrap_or(false)
}

fn unauthorized() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        Json(json!({"error": "unauthorized: send X-Mnemo-Token"})),
    )
        .into_response()
}

fn failed(err: impl std::fmt::Display) -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({"error": err.to_string()})),
    )
        .into_response()
}

fn limit_of(q: &HashMap<String, String>, key: &str, default: i64) -> i64 {
    q.get(key)
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(default)
        .clamp(1, 500)
}

async fn healthz() -> Json<Value> {
    Json(json!({"ok": true, "service": "mnemo"}))
}

async fn index() -> Html<&'static str> {
    Html(include_str!("../web/index.html"))
}

async fn api_stats(State(app): State<Arc<App>>, headers: HeaderMap) -> Response {
    if !allowed(&app, &headers) {
        return unauthorized();
    }
    match app.store.stats().await {
        Ok(v) => Json(json!({
            "stats": v,
            "model": app.llm.model(),
            "min_priority": app.cfg.min_priority,
            "sessions_db": app.cfg.sessions_db.to_string_lossy(),
        }))
        .into_response(),
        Err(e) => failed(e),
    }
}

async fn api_backlog(
    State(app): State<Arc<App>>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    if !allowed(&app, &headers) {
        return unauthorized();
    }
    let min = q
        .get("min_priority")
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(app.cfg.min_priority);
    match app.store.backlog(min, limit_of(&q, "limit", 50)).await {
        Ok(items) => Json(json!({"min_priority": min, "items": items})).into_response(),
        Err(e) => failed(e),
    }
}

async fn api_brief(
    State(app): State<Arc<App>>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    if !allowed(&app, &headers) {
        return unauthorized();
    }
    let Some(id) = q.get("session_id") else {
        return (StatusCode::BAD_REQUEST, Json(json!({"error": "session_id required"})))
            .into_response();
    };
    match app.store.brief(id).await {
        Ok(Some(brief)) => {
            let gaps = app.store.gaps(id).await.unwrap_or_default();
            Json(json!({"brief": brief, "gaps": gaps})).into_response()
        }
        Ok(None) => (StatusCode::NOT_FOUND, Json(json!({"error": "no brief"}))).into_response(),
        Err(e) => failed(e),
    }
}

async fn api_gaps(
    State(app): State<Arc<App>>,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    if !allowed(&app, &headers) {
        return unauthorized();
    }
    let Some(id) = q.get("session_id") else {
        return (StatusCode::BAD_REQUEST, Json(json!({"error": "session_id required"})))
            .into_response();
    };
    match app.store.gaps(id).await {
        Ok(gaps) => Json(json!({"session_id": id, "gaps": gaps})).into_response(),
        Err(e) => failed(e),
    }
}

async fn api_wordlist(State(app): State<Arc<App>>, headers: HeaderMap) -> Response {
    if !allowed(&app, &headers) {
        return unauthorized();
    }
    match app.store.terms().await {
        Ok(terms) => {
            let text = terms
                .iter()
                .map(|(t, _)| t.as_str())
                .collect::<Vec<_>>()
                .join("\n");
            (
                [(axum::http::header::CONTENT_TYPE, "text/plain; charset=utf-8")],
                text,
            )
                .into_response()
        }
        Err(e) => failed(e),
    }
}

async fn api_scan(
    State(app): State<Arc<App>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Response {
    if !allowed(&app, &headers) {
        return unauthorized();
    }
    let since = body["since"].as_f64().unwrap_or(0.0);
    let limit = body["limit"].as_u64().unwrap_or(20) as usize;
    let briefs = body["briefs"].as_bool().unwrap_or(true);
    let publish = body["publish"].as_bool().unwrap_or(false);
    match crate::scan::run(&app, since, limit, briefs, publish).await {
        Ok(report) => Json(report).into_response(),
        Err(e) => failed(e),
    }
}

async fn mcp_get() -> Response {
    (
        StatusCode::METHOD_NOT_ALLOWED,
        Json(json!({"error": "POST JSON-RPC here"})),
    )
        .into_response()
}

async fn mcp(State(app): State<Arc<App>>, headers: HeaderMap, Json(body): Json<Value>) -> Response {
    if !allowed(&app, &headers) {
        return unauthorized();
    }
    let id = body.get("id").cloned().unwrap_or(Value::Null);
    let method = body["method"].as_str().unwrap_or_default().to_string();
    let params = body.get("params").cloned().unwrap_or(json!({}));

    let result: Result<Value, String> = match method.as_str() {
        "initialize" => Ok(json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {"tools": {"listChanged": false}},
            "serverInfo": {"name": "mnemo", "version": env!("CARGO_PKG_VERSION")},
        })),
        "notifications/initialized" | "notifications/cancelled" => {
            return StatusCode::ACCEPTED.into_response()
        }
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": tools()})),
        "tools/call" => call_tool(&app, &params).await,
        other => Err(format!("unknown method: {other}")),
    };

    match result {
        Ok(value) => Json(json!({"jsonrpc": "2.0", "id": id, "result": value})).into_response(),
        Err(message) => Json(json!({
            "jsonrpc": "2.0", "id": id,
            "error": {"code": -32601, "message": message},
        }))
        .into_response(),
    }
}

fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": "mnemo_backlog",
            "description": "Conversations Marc cares about, most important first, with the three axes (matiere, points, importance) and the priority.",
            "inputSchema": {"type": "object", "properties": {
                "min_priority": {"type": "number", "description": "default 8"},
                "limit": {"type": "integer", "description": "default 50"}}}
        }),
        json!({
            "name": "mnemo_brief",
            "description": "The explanation sheet for one conversation: what he did not understand and the corrected model, in French markdown.",
            "inputSchema": {"type": "object", "properties": {
                "session_id": {"type": "string"}}, "required": ["session_id"]}
        }),
        json!({
            "name": "mnemo_gaps",
            "description": "The points Marc did not understand in one conversation, each with the quote and the explanation.",
            "inputSchema": {"type": "object", "properties": {
                "session_id": {"type": "string"}}, "required": ["session_id"]}
        }),
        json!({
            "name": "mnemo_scan",
            "description": "Score new conversations, extract the gaps and write the briefs. Enqueues into the podcast pipeline when publish is true.",
            "inputSchema": {"type": "object", "properties": {
                "since": {"type": "number"}, "limit": {"type": "integer"},
                "briefs": {"type": "boolean"}, "publish": {"type": "boolean"}}}
        }),
        json!({
            "name": "mnemo_wordlist",
            "description": "The vocabulary of Marc's own conversations, ready for a typing drill.",
            "inputSchema": {"type": "object", "properties": {}}
        }),
    ]
}

async fn call_tool(app: &App, params: &Value) -> Result<Value, String> {
    let name = params["name"].as_str().unwrap_or_default().to_string();
    let args = params.get("arguments").cloned().unwrap_or(json!({}));
    let payload = match name.as_str() {
        "mnemo_backlog" => {
            let min = args["min_priority"]
                .as_f64()
                .unwrap_or(app.cfg.min_priority);
            let limit = args["limit"].as_i64().unwrap_or(50);
            app.store
                .backlog(min, limit)
                .await
                .map(|items| json!({"items": items}))
                .map_err(|e| e.to_string())?
        }
        "mnemo_brief" => {
            let id = args["session_id"].as_str().unwrap_or_default();
            match app.store.brief(id).await.map_err(|e| e.to_string())? {
                Some(brief) => json!({"brief": brief}),
                None => json!({"error": "no brief for this session"}),
            }
        }
        "mnemo_gaps" => {
            let id = args["session_id"].as_str().unwrap_or_default();
            json!({"gaps": app.store.gaps(id).await.map_err(|e| e.to_string())?})
        }
        "mnemo_scan" => {
            crate::scan::run(
                app,
                args["since"].as_f64().unwrap_or(0.0),
                args["limit"].as_u64().unwrap_or(20) as usize,
                args["briefs"].as_bool().unwrap_or(true),
                args["publish"].as_bool().unwrap_or(false),
            )
            .await
            .map_err(|e| e.to_string())?
        }
        "mnemo_wordlist" => {
            let terms = app.store.terms().await.map_err(|e| e.to_string())?;
            json!({"words": terms.iter().map(|(t, _)| t.clone()).collect::<Vec<_>>()})
        }
        other => return Err(format!("unknown tool: {other}")),
    };
    Ok(json!({
        "content": [{"type": "text", "text": serde_json::to_string_pretty(&payload).unwrap_or_default()}],
        "isError": false
    }))
}
