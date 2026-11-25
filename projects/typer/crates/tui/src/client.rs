//! Blocking WebSocket client for `ws://` and `wss://` URLs.
//!
//! TLS is rustls with the webpki trust store compiled in: the binary carries
//! its own roots, so `wss://typer.marcpartensky.com/ws` works from any shell
//! with nothing installed and no port forward. `ws://` stays supported for a
//! local server.

use std::io::{ErrorKind, Read, Write};
use std::net::TcpStream;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::Value;
use typer_core::coders;
use typer_core::ws::{self, Framer, Op};

/// Anything the client can speak through: a plain socket or a TLS session.
trait Stream: Read + Write {}
impl<T: Read + Write> Stream for T {}

pub struct Client {
    stream: Box<dyn Stream>,
    framer: Framer,
    url: String,
}

impl Client {
    pub fn connect(url: &str) -> Result<Self, String> {
        let (tls, host, port, path) = parse(url)?;
        let tcp = TcpStream::connect((host.as_str(), port))
            .map_err(|err| format!("connect {host}:{port}: {err}"))?;
        let _ = tcp.set_nodelay(true);
        // Kept aside for `set_read_timeout`: a dup'd descriptor shares the
        // socket, so the option applies under the TLS wrapper too.
        let control = tcp
            .try_clone()
            .map_err(|err| format!("connect {host}:{port}: {err}"))?;

        let mut stream: Box<dyn Stream> = if tls {
            let mut roots = rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let config = rustls::ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth();
            let name = rustls::pki_types::ServerName::try_from(host.clone())
                .map_err(|_| format!("{url}: bad server name"))?;
            let session = rustls::ClientConnection::new(Arc::new(config), name)
                .map_err(|err| format!("{url}: tls: {err}"))?;
            Box::new(rustls::StreamOwned::new(session, tcp))
        } else {
            Box::new(tcp)
        };

        let key = coders::base64(&coders::nonce());
        let request = format!(
            "GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n\
             Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n\
             Sec-WebSocket-Version: 13\r\nUser-Agent: typer-race\r\n\r\n"
        );
        stream
            .write_all(request.as_bytes())
            .map_err(|err| format!("handshake write: {err}"))?;

        let mut buf: Vec<u8> = Vec::new();
        let mut chunk = [0u8; 1024];
        let head_end = loop {
            if let Some(pos) = find(&buf, b"\r\n\r\n") {
                break pos;
            }
            if buf.len() > 16 * 1024 {
                return Err("handshake response too large".to_string());
            }
            let read = stream
                .read(&mut chunk)
                .map_err(|err| format!("handshake read: {err}"))?;
            if read == 0 {
                return Err("handshake closed".to_string());
            }
            buf.extend_from_slice(&chunk[..read]);
        };

        let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
        let status = head.lines().next().unwrap_or_default().to_string();
        if !status.contains(" 101") {
            return Err(format!("upgrade refused: {status}"));
        }
        if !head.contains(&coders::ws_accept(&key)) {
            return Err("bad Sec-WebSocket-Accept".to_string());
        }

        control
            .set_read_timeout(Some(Duration::from_millis(50)))
            .map_err(|err| err.to_string())?;

        let mut framer = Framer::new();
        let rest = buf[head_end + 4..].to_vec();
        if !rest.is_empty() {
            framer.push(&rest);
        }

        Ok(Self {
            stream,
            framer,
            url: url.to_string(),
        })
    }

    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn send(&mut self, message: &Value) -> Result<(), String> {
        let data = serde_json::to_vec(message).map_err(|err| err.to_string())?;
        let nonce = coders::nonce();
        let mask = [nonce[0], nonce[1], nonce[2], nonce[3]];
        let frame = ws::encode_masked(&data, 0x1, mask);
        self.stream
            .write_all(&frame)
            .map_err(|err| format!("send: {err}"))
    }

    /// Next JSON message, or `None` once `timeout` has elapsed.
    pub fn poll(&mut self, timeout: Duration) -> Result<Option<Value>, String> {
        let deadline = Instant::now() + timeout;
        loop {
            match self.framer.next_message() {
                Ok(Some((op, payload))) => match op {
                    Op::Text | Op::Binary => {
                        if let Ok(value) = serde_json::from_slice::<Value>(&payload) {
                            return Ok(Some(value));
                        }
                    }
                    Op::Close => return Err("server closed the room".to_string()),
                    Op::Ping => {
                        let nonce = coders::nonce();
                        let mask = [nonce[0], nonce[1], nonce[2], nonce[3]];
                        let _ = self
                            .stream
                            .write_all(&ws::encode_masked(&payload, 0x0A, mask));
                    }
                    _ => {}
                },
                Ok(None) => {}
                Err(err) => return Err(err),
            }

            let mut chunk = [0u8; 4096];
            match self.stream.read(&mut chunk) {
                Ok(0) => return Err("connection closed".to_string()),
                Ok(read) => self.framer.push(&chunk[..read]),
                Err(err) => match err.kind() {
                    ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted => {
                        if Instant::now() >= deadline {
                            return Ok(None);
                        }
                        std::thread::sleep(Duration::from_millis(2));
                    }
                    _ => return Err(err.to_string()),
                },
            }
        }
    }
}

/// `(tls, host, port, path)` for a `ws://` or `wss://` URL.
fn parse(url: &str) -> Result<(bool, String, u16, String), String> {
    let (tls, rest, default_port) = if let Some(rest) = url.strip_prefix("ws://") {
        (false, rest, 80u16)
    } else if let Some(rest) = url.strip_prefix("wss://") {
        (true, rest, 443u16)
    } else {
        return Err(format!("{url}: expected a ws:// or wss:// URL"));
    };
    let (authority, path) = match rest.find('/') {
        Some(pos) => (&rest[..pos], &rest[pos..]),
        None => (rest, "/ws"),
    };
    let path = if path.is_empty() {
        "/ws".to_string()
    } else {
        path.to_string()
    };
    match authority.rsplit_once(':') {
        Some((host, port)) => {
            let port = port
                .parse::<u16>()
                .map_err(|_| format!("bad port in {url}"))?;
            Ok((tls, host.to_string(), port, path))
        }
        None => Ok((tls, authority.to_string(), default_port, path)),
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_split_into_scheme_host_port_path() {
        assert_eq!(
            parse("ws://127.0.0.1:9146/ws").unwrap(),
            (false, "127.0.0.1".to_string(), 9146, "/ws".to_string())
        );
        assert_eq!(
            parse("ws://example.org").unwrap(),
            (false, "example.org".to_string(), 80, "/ws".to_string())
        );
        assert_eq!(
            parse("wss://typer.marcpartensky.com/ws").unwrap(),
            (
                true,
                "typer.marcpartensky.com".to_string(),
                443,
                "/ws".to_string()
            )
        );
        assert!(parse("https://example.org/ws").is_err());
    }
}
