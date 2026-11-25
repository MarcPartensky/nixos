// shlink-mcp-rs: minimal Rust port of the flake's shlink MCP server.
//
// Goal: measure what the MCP layer really costs, keeping
// strictly the same JSON-RPC contract and the same HTTP calls as
// services/shlink-mcp/server.py (FastMCP).
//
// Zero dependency beyond serde_json: stdio transport, homemade HTTP/1.1 client
// (the target Shlink API is cleartext on loopback). A real port would keep
// ureq+rustls for HTTPS; it changes nothing for the measurements, time goes
// into the network and the backend, not into the parser.

use serde_json::{json, Map, Value};
use std::io::{self, BufRead, Read, Write};
use std::net::TcpStream;

const TOOLS_JSON: &str = include_str!("../tools.json");

struct Cfg {
    host: String,
    port: u16,
    base_path: String,
    key: String,
    allow_writes: bool,
}

fn env_or(k: &str, d: &str) -> String {
    std::env::var(k).unwrap_or_else(|_| d.to_string())
}

fn api_key() -> String {
    let key_file = env_or("SHLINK_API_KEY_FILE", "");
    if !key_file.is_empty() {
        if let Ok(s) = std::fs::read_to_string(&key_file) {
            let s = s.trim().to_string();
            if !s.is_empty() {
                return s;
            }
        }
    }
    let k = env_or("SHLINK_API_KEY", "");
    if k.is_empty() {
        eprintln!("Shlink API key missing");
    }
    k
}

fn cfg() -> Cfg {
    let url = env_or("SHLINK_URL", "http://127.0.0.1:8097");
    let url = url.trim_end_matches('/').to_string();
    let rest = url.strip_prefix("http://").unwrap_or(&url).to_string();
    let (authority, base_path) = match rest.find('/') {
        Some(i) => (rest[..i].to_string(), rest[i..].to_string()),
        None => (rest, String::new()),
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) => (h.to_string(), p.parse().unwrap_or(80)),
        None => (authority, 80),
    };
    Cfg {
        host,
        port,
        base_path,
        key: api_key(),
        allow_writes: env_or("SHLINK_ALLOW_WRITES", "0") == "1",
    }
}

fn pct(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// urlencode like urllib.parse.urlencode(..., doseq=True) on an already-cleaned map.
fn encode_query(q: &[(&str, Value)]) -> String {
    let mut parts: Vec<String> = Vec::new();
    for (k, v) in q {
        match v {
            Value::Null => {}
            Value::Array(a) => {
                for item in a {
                    parts.push(format!("{}={}", pct(k), pct(&scalar(item))));
                }
            }
            other => parts.push(format!("{}={}", pct(k), pct(&scalar(other)))),
        }
    }
    parts.join("&")
}

fn scalar(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

struct Resp {
    status: u16,
    body: String,
}

fn http(c: &Cfg, method: &str, path: &str, query: &str, body: Option<&Value>) -> Result<Resp, String> {
    let mut target = format!("{}/rest/v3{}", c.base_path, path);
    if !query.is_empty() {
        target.push('?');
        target.push_str(query);
    }
    let payload = body.map(|b| b.to_string()).unwrap_or_default();
    let mut head = format!(
        "{} {} HTTP/1.1\r\nHost: {}:{}\r\nAccept: application/json\r\nX-Api-Key: {}\r\nConnection: close\r\n",
        method, target, c.host, c.port, c.key
    );
    if body.is_some() {
        head.push_str("Content-Type: application/json\r\n");
        head.push_str(&format!("Content-Length: {}\r\n", payload.len()));
    }
    head.push_str("\r\n");
    head.push_str(&payload);

    let mut s = TcpStream::connect((c.host.as_str(), c.port)).map_err(|e| format!("unreachable: {}", e))?;
    let timeout = env_or("SHLINK_TIMEOUT", "30").parse::<u64>().unwrap_or(30);
    let _ = s.set_read_timeout(Some(std::time::Duration::from_secs(timeout)));
    s.write_all(head.as_bytes()).map_err(|e| format!("unreachable: {}", e))?;
    let mut raw = Vec::new();
    s.read_to_end(&mut raw).map_err(|e| format!("unreachable: {}", e))?;

    let sep = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or("empty HTTP response")?;
    let head_txt = String::from_utf8_lossy(&raw[..sep]).to_string();
    let mut body_bytes = raw[sep + 4..].to_vec();
    let status: u16 = head_txt
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or("unreadable HTTP status")?;
    let chunked = head_txt.to_lowercase().contains("transfer-encoding: chunked");
    if chunked {
        body_bytes = dechunk(&body_bytes);
    }
    Ok(Resp {
        status,
        body: String::from_utf8_lossy(&body_bytes).to_string(),
    })
}

fn dechunk(b: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < b.len() {
        let nl = match b[i..].windows(2).position(|w| w == b"\r\n") {
            Some(p) => i + p,
            None => break,
        };
        let size_s = String::from_utf8_lossy(&b[i..nl]).to_string();
        let size = usize::from_str_radix(size_s.trim().split(';').next().unwrap_or("0"), 16).unwrap_or(0);
        if size == 0 {
            break;
        }
        let start = nl + 2;
        let end = (start + size).min(b.len());
        out.extend_from_slice(&b[start..end]);
        i = end + 2;
    }
    out
}

fn call(c: &Cfg, method: &str, path: &str, query: &[(&str, Value)], body: Option<&Value>) -> Value {
    let q = encode_query(query);
    match http(c, method, path, &q, body) {
        Ok(r) => {
            let parsed: Value = serde_json::from_str(&r.body).unwrap_or(Value::String(r.body.clone()));
            json!({"status": r.status, "body": parsed})
        }
        Err(e) => json!({"status": 0, "error": e}),
    }
}

fn wrong_status(c: &Cfg, status: u16, body: &str) -> Value {
    let payload = serde_json::from_str::<Value>(body)
        .unwrap_or_else(|_| Value::String(body.chars().take(2000).collect()));
    let _ = c;
    json!({"status": status, "error": payload})
}

fn call_checked(c: &Cfg, method: &str, path: &str, query: &[(&str, Value)], body: Option<&Value>) -> Value {
    let q = encode_query(query);
    match http(c, method, path, &q, body) {
        Ok(r) if (200..300).contains(&r.status) => {
            let parsed: Value = serde_json::from_str(&r.body).unwrap_or(Value::String(r.body.clone()));
            json!({"status": r.status, "body": parsed})
        }
        Ok(r) => wrong_status(c, r.status, &r.body),
        Err(e) => json!({"status": 0, "error": e}),
    }
}

fn write_guard(c: &Cfg, action: &str, payload: Value) -> Value {
    if c.allow_writes {
        Value::Null
    } else {
        json!({
            "dry_run": true,
            "reason": "SHLINK_ALLOW_WRITES=0: writes disabled in the MCP server config",
            "action": action,
            "payload": payload,
        })
    }
}

fn sarg(a: &Map<String, Value>, k: &str) -> Value {
    a.get(k).cloned().unwrap_or(Value::Null)
}

fn iarg(a: &Map<String, Value>, k: &str, d: i64) -> Value {
    a.get(k).cloned().unwrap_or(json!(d))
}

fn bstr(b: bool) -> Value {
    json!(b.to_string())
}

fn dispatch(c: &Cfg, name: &str, args: &Map<String, Value>) -> Value {
    match name {
        "shlink_health" => call_checked(c, "GET", "/health", &[], None),
        "shlink_list_short_urls" => {
            let mut q: Vec<(&str, Value)> = vec![
                ("searchTerm", sarg(args, "search_term")),
                ("domain", sarg(args, "domain")),
                ("orderBy", sarg(args, "order_by")),
                ("page", iarg(args, "page", 1)),
                ("itemsPerPage", iarg(args, "items_per_page", 20)),
            ];
            if let Some(t) = args.get("tags").filter(|v| !v.is_null()) {
                q.push(("tags[]", t.clone()));
            }
            if let Some(t) = args.get("exclude_tags").filter(|v| !v.is_null()) {
                q.push(("excludeTags[]", t.clone()));
            }
            call_checked(c, "GET", "/short-urls", &q, None)
        }
        "shlink_get_short_url" => {
            let code = scalar(&sarg(args, "short_code"));
            call_checked(
                c,
                "GET",
                &format!("/short-urls/{}", pct(&code)),
                &[("domain", sarg(args, "domain"))],
                None,
            )
        }
        "shlink_create_short_url" => {
            let mut body = Map::new();
            body.insert("longUrl".into(), sarg(args, "long_url"));
            for (src, dst) in [
                ("custom_slug", "customSlug"),
                ("tags", "tags"),
                ("domain", "domain"),
                ("title", "title"),
                ("valid_since", "validSince"),
                ("valid_until", "validUntil"),
                ("max_visits", "maxVisits"),
                ("crawlable", "crawlable"),
            ] {
                if let Some(v) = args.get(src).filter(|v| !v.is_null()) {
                    body.insert(dst.into(), v.clone());
                }
            }
            let confirm = args.get("confirm").and_then(|v| v.as_bool()).unwrap_or(false);
            let body = Value::Object(body);
            if !confirm {
                let g = write_guard(c, "create", body.clone());
                if g.is_null() {
                    // nothing
                } else {
                    return g;
                }
            }
            call_checked(c, "POST", "/short-urls", &[], Some(&body))
        }
        "shlink_update_short_url" => {
            let code = scalar(&sarg(args, "short_code"));
            let mut body = Map::new();
            for (src, dst) in [
                ("long_url", "longUrl"),
                ("custom_slug", "customSlug"),
                ("tags", "tags"),
                ("title", "title"),
                ("valid_since", "validSince"),
                ("valid_until", "validUntil"),
                ("max_visits", "maxVisits"),
            ] {
                if let Some(v) = args.get(src).filter(|v| !v.is_null()) {
                    body.insert(dst.into(), v.clone());
                }
            }
            let body = Value::Object(body);
            let confirm = args.get("confirm").and_then(|v| v.as_bool()).unwrap_or(false);
            if !confirm {
                let g = write_guard(c, "update", body.clone());
                if !g.is_null() {
                    return g;
                }
            }
            call_checked(c, "PATCH", &format!("/short-urls/{}", pct(&code)), &[], Some(&body))
        }
        "shlink_delete_short_url" => {
            let code = scalar(&sarg(args, "short_code"));
            let confirm = args.get("confirm").and_then(|v| v.as_bool()).unwrap_or(false);
            if !confirm {
                let g = write_guard(c, "delete", json!({"shortCode": code}));
                if !g.is_null() {
                    return g;
                }
            }
            call_checked(
                c,
                "DELETE",
                &format!("/short-urls/{}", pct(&code)),
                &[("domain", sarg(args, "domain"))],
                None,
            )
        }
        "shlink_visits" => {
            let exclude = args.get("exclude_bots").and_then(|v| v.as_bool()).unwrap_or(true);
            let mut q: Vec<(&str, Value)> = vec![
                ("startDate", sarg(args, "start_date")),
                ("endDate", sarg(args, "end_date")),
                ("excludeBots", bstr(exclude)),
                ("page", iarg(args, "page", 1)),
                ("itemsPerPage", iarg(args, "items_per_page", 20)),
            ];
            let code = args.get("short_code").map(scalar).unwrap_or_default();
            if !code.is_empty() {
                q.push(("domain", sarg(args, "domain")));
                return call_checked(c, "GET", &format!("/short-urls/{}/visits", pct(&code)), &q, None);
            }
            if let Some(tag) = args.get("tag").map(scalar).filter(|t| !t.is_empty()) {
                return call_checked(c, "GET", &format!("/tags/{}/visits", pct(&tag)), &q, None);
            }
            if let Some(d) = args.get("domain").map(scalar).filter(|d| !d.is_empty()) {
                q.push(("domain", json!(d)));
                return call_checked(c, "GET", &format!("/domains/{}/visits", pct(&d)), &q, None);
            }
            call_checked(c, "GET", "/visits", &q, None)
        }
        "shlink_tags" => {
            let with = args.get("with_stats").and_then(|v| v.as_bool()).unwrap_or(true);
            let path = if with { "/tags/stats" } else { "/tags" };
            call_checked(c, "GET", path, &[("withStats", bstr(with))], None)
        }
        "shlink_domains" => call_checked(c, "GET", "/domains", &[], None),
        "shlink_request" => {
            let method = scalar(&sarg(args, "method")).to_uppercase();
            if !matches!(method.as_str(), "GET" | "POST" | "PATCH" | "PUT" | "DELETE") {
                return json!({"error": format!("unsupported method: {}", method)});
            }
            let mut path = scalar(&sarg(args, "path"));
            if !path.starts_with('/') {
                path.insert(0, '/');
            }
            let confirm = args.get("confirm").and_then(|v| v.as_bool()).unwrap_or(false);
            let mut q: Vec<(&str, Value)> = Vec::new();
            if let Some(Value::Object(m)) = args.get("query") {
                for (k, v) in m {
                    q.push((k.as_str(), v.clone()));
                }
            }
            let body = args.get("body").filter(|v| !v.is_null()).cloned();
            if method != "GET" && !confirm {
                let g = write_guard(c, &method, json!({"path": path, "query": args.get("query"), "body": body}));
                if !g.is_null() {
                    return g;
                }
            }
            call_checked(c, &method, &path, &q, body.as_ref())
        }
        other => json!({"error": format!("unknown tool: {}", other)}),
    }
}

fn main() {
    let c = cfg();
    let stdin = io::stdin();
    let mut out = io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let id = msg.get("id").cloned().unwrap_or(Value::Null);
        let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
        if id.is_null() {
            continue; // notification: no response
        }
        let result = match method {
            "initialize" => json!({
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "shlink", "version": "0.1.0-rs"},
            }),
            "tools/list" => {
                let tools: Value = serde_json::from_str(TOOLS_JSON).unwrap_or(json!([]));
                json!({"tools": tools})
            }
            "tools/call" => {
                let p = msg.get("params").cloned().unwrap_or(json!({}));
                let name = p.get("name").and_then(|n| n.as_str()).unwrap_or("");
                let empty = Map::new();
                let args = p.get("arguments").and_then(|a| a.as_object()).unwrap_or(&empty);
                let payload = dispatch(&c, name, args);
                let pretty = std::env::var("SHLINK_RS_PRETTY").map(|v| v == "1").unwrap_or(false);
                let text = if pretty {
                    serde_json::to_string_pretty(&payload).unwrap_or_default()
                } else {
                    payload.to_string()
                };
                let is_err = payload.get("status").and_then(|s| s.as_u64()).map(|s| s == 0).unwrap_or(false);
                json!({"content": [{"type": "text", "text": text}], "isError": is_err})
            }
            "ping" => json!({}),
            other => {
                let err = json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": format!("unknown method: {}", other)}});
                let _ = writeln!(out, "{}", err);
                let _ = out.flush();
                continue;
            }
        };
        let resp = json!({"jsonrpc": "2.0", "id": id, "result": result});
        let _ = writeln!(out, "{}", resp);
        let _ = out.flush();
    }
}
