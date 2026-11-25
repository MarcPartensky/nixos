//! Static assets: the browser app under `--root` is served as-is.
//!
//! The front-end has no build step, so the server only needs extension-based
//! content types, a revalidation cache policy (the URLs are stable, the content
//! is not) and the CSP the app was written for.

use std::path::{Path, PathBuf};

use tokio::io::AsyncWriteExt;
use tokio::net::tcp::OwnedWriteHalf;

use crate::App;

// `connect-src 'self'` covers the same-origin `wss://` socket: CSP3 maps a
// ws/wss URL to its http/https counterpart when matching 'self'. Spelling
// `ws://'self'` is not a valid source expression (a host cannot be `'self'`),
// so browsers drop it and log a console warning.
const CSP: &str = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; \
                   img-src 'self' data:; connect-src 'self'; \
                   form-action 'none'; frame-ancestors 'none'";

/// `%41` -> `A`. A malformed escape rejects the path instead of guessing.
pub fn percent_decode(input: &str) -> Option<String> {
    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn content_type(ext: &str) -> &'static str {
    match ext {
        "html" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "txt" => "text/plain; charset=utf-8",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        "webmanifest" => "application/manifest+json",
        _ => "application/octet-stream",
    }
}

fn cache_control(ext: &str) -> &'static str {
    match ext {
        "html" | "css" | "js" => "no-cache",
        _ => "public, max-age=3600",
    }
}

async fn resolve(app: &App, candidate: &Path) -> Option<PathBuf> {
    let full = tokio::fs::canonicalize(candidate).await.ok()?;
    if !full.starts_with(app.root.as_ref()) {
        return None;
    }
    if !tokio::fs::metadata(&full).await.ok()?.is_file() {
        return None;
    }
    Some(full)
}

pub async fn serve(
    writer: &mut OwnedWriteHalf,
    app: &App,
    path: &str,
    head_only: bool,
) -> std::io::Result<()> {
    let mut path = path.to_string();
    if path.ends_with('/') {
        path.push_str("index.html");
    }

    let candidate = app.root.join(path.trim_start_matches('/'));
    let Some(full) = resolve(app, &candidate).await else {
        return crate::reply(writer, 404, "not found\n").await;
    };
    let Ok(body) = tokio::fs::read(&full).await else {
        return crate::reply(writer, 404, "not found\n").await;
    };

    let ext = full
        .extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    let mut head = String::with_capacity(512);
    head.push_str("HTTP/1.1 200 OK\r\n");
    head.push_str(&format!("Content-Type: {}\r\n", content_type(&ext)));
    head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    head.push_str("Connection: close\r\n");
    head.push_str(&format!("Cache-Control: {}\r\n", cache_control(&ext)));
    head.push_str("X-Content-Type-Options: nosniff\r\n");
    head.push_str("Referrer-Policy: no-referrer\r\n");
    head.push_str("X-Frame-Options: DENY\r\n");
    if ext == "html" {
        head.push_str(&format!("Content-Security-Policy: {CSP}\r\n"));
    }
    head.push_str("\r\n");

    writer.write_all(head.as_bytes()).await?;
    if !head_only {
        writer.write_all(&body).await?;
    }
    writer.flush().await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_decoding_rejects_truncated_escapes() {
        assert_eq!(
            percent_decode("/lang/french%32%30%30").as_deref(),
            Some("/lang/french200")
        );
        assert_eq!(percent_decode("/a%2").as_deref(), None);
        assert_eq!(percent_decode("/a%zz").as_deref(), None);
        assert_eq!(
            percent_decode("/../etc/passwd").as_deref(),
            Some("/../etc/passwd")
        );
    }

    #[test]
    fn content_types_follow_the_extension() {
        assert_eq!(content_type("js"), "text/javascript; charset=utf-8");
        assert_eq!(content_type("bin"), "application/octet-stream");
        assert_eq!(cache_control("html"), "no-cache");
    }
}
