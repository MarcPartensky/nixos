//! typer-server: the static front-end and the race rooms on one port.
//!
//! One process, no runtime but Rust: `--root` is served as-is (the browser app
//! needs no build), `/ws` speaks the room protocol, and everything else is a
//! 404. Rooms live in RAM; the process keeps no state worth backing up.

mod http;
mod hub;

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

use hub::HubMsg;
use typer_core::ws::{self, Framer, Op};
use typer_core::{ClientMsg, Pools};

const HEAD_LIMIT: usize = 16 * 1024;
const READ_CHUNK: usize = 4096;
const CONNECTIONS_PER_MINUTE: usize = 30;

const USAGE: &str = "typer-server --root <dir> [--port 9146] [--host 127.0.0.1]";

#[derive(Clone)]
pub struct App {
    pub root: Arc<PathBuf>,
    pub hub: mpsc::UnboundedSender<HubMsg>,
    conn: Arc<AtomicU64>,
    throttle: Arc<Mutex<HashMap<IpAddr, Vec<Instant>>>>,
}

impl App {
    /// Thirty new sockets per client per minute. Rooms are capped separately:
    /// this only stops a loop from opening thousands of connections.
    fn throttled(&self, ip: IpAddr) -> bool {
        let now = Instant::now();
        let mut map = match self.throttle.lock() {
            Ok(guard) => guard,
            Err(poison) => poison.into_inner(),
        };
        if map.len() > 5000 {
            map.clear();
        }
        let bucket = map.entry(ip).or_default();
        bucket.retain(|at| now.duration_since(*at) < Duration::from_secs(60));
        bucket.push(now);
        bucket.len() > CONNECTIONS_PER_MINUTE
    }
}

#[tokio::main]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("typer-server: {err}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut root = PathBuf::from(".");
    let mut port: u16 = 9146;
    let mut host = String::from("127.0.0.1");

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--root" => {
                i += 1;
                root = PathBuf::from(args.get(i).ok_or("--root needs a directory")?);
            }
            "--port" => {
                i += 1;
                port = args.get(i).ok_or("--port needs a number")?.parse()?;
            }
            "--host" => {
                i += 1;
                host = args.get(i).ok_or("--host needs an address")?.clone();
            }
            "-h" | "--help" => {
                println!("{USAGE}");
                return Ok(());
            }
            other => return Err(format!("unknown argument: {other}\n{USAGE}").into()),
        }
        i += 1;
    }

    let root = std::fs::canonicalize(&root)?;
    let pools = Pools::load(&root)?;
    if pools.is_empty() {
        return Err(format!("no word list under {}/lang", root.display()).into());
    }
    let languages = pools.ids().join(", ");

    let app = App {
        root: Arc::new(root.clone()),
        hub: hub::spawn(pools),
        conn: Arc::new(AtomicU64::new(1)),
        throttle: Arc::new(Mutex::new(HashMap::new())),
    };

    let listener = TcpListener::bind((host.as_str(), port)).await?;
    println!(
        "typer-server: serving {} and /ws on http://{host}:{port} (langs: {languages})",
        root.display()
    );

    loop {
        match listener.accept().await {
            Ok((stream, peer)) => {
                let app = app.clone();
                tokio::spawn(async move {
                    if let Err(err) = handle(stream, peer, app).await {
                        if !matches!(
                            err.kind(),
                            std::io::ErrorKind::ConnectionReset
                                | std::io::ErrorKind::BrokenPipe
                                | std::io::ErrorKind::UnexpectedEof
                        ) {
                            eprintln!("typer-server: {peer}: {err}");
                        }
                    }
                });
            }
            Err(err) => eprintln!("typer-server: accept: {err}"),
        }
    }
}

async fn handle(stream: TcpStream, peer: SocketAddr, app: App) -> std::io::Result<()> {
    let _ = stream.set_nodelay(true);
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut head: Vec<u8> = Vec::with_capacity(1024);
    let mut chunk = [0u8; READ_CHUNK];

    let head_end = loop {
        if let Some(pos) = find(&head, b"\r\n\r\n") {
            break pos;
        }
        if head.len() > HEAD_LIMIT {
            return reply(&mut write_half, 400, "bad request\n").await;
        }
        let read = reader.read(&mut chunk).await?;
        if read == 0 {
            return Ok(());
        }
        head.extend_from_slice(&chunk[..read]);
    };

    let head_text = String::from_utf8_lossy(&head[..head_end]).to_string();
    let rest = head[head_end + 4..].to_vec();

    let mut lines = head_text.split("\r\n");
    let request = lines.next().unwrap_or_default();
    let mut parts = request.split_whitespace();
    let method = parts.next().unwrap_or("GET").to_string();
    let target = parts.next().unwrap_or("/").to_string();

    let mut headers: HashMap<String, String> = HashMap::new();
    for line in lines {
        if let Some((key, value)) = line.split_once(':') {
            headers.insert(key.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }

    // Behind newt every socket comes from 127.0.0.1: the client IP is in
    // X-Forwarded-For, and that is what the rate limit must follow.
    let ip = headers
        .get("x-forwarded-for")
        .and_then(|value| value.split(',').next())
        .and_then(|value| value.trim().parse::<IpAddr>().ok())
        .unwrap_or_else(|| peer.ip());
    if app.throttled(ip) {
        return reply(&mut write_half, 429, "too many connections\n").await;
    }

    let raw_path = target.split('?').next().unwrap_or("/");
    let path = http::percent_decode(raw_path).unwrap_or_else(|| "/".to_string());
    if path.contains('\0') {
        return reply(&mut write_half, 404, "not found\n").await;
    }

    let upgrade = headers
        .get("upgrade")
        .map(|value| value.eq_ignore_ascii_case("websocket"))
        .unwrap_or(false);

    if upgrade {
        if path != "/ws" {
            return reply(&mut write_half, 404, "not found\n").await;
        }
        let key = headers
            .get("sec-websocket-key")
            .cloned()
            .unwrap_or_default();
        let version_ok = headers
            .get("sec-websocket-version")
            .map(|value| value == "13")
            .unwrap_or(false);
        if key.is_empty() || !version_ok {
            return reply(&mut write_half, 400, "bad websocket handshake\n").await;
        }
        let accept = typer_core::coders::ws_accept(&key);
        let response = format!(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\
             Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
        );
        write_half.write_all(response.as_bytes()).await?;
        write_half.flush().await?;
        return session(reader, rest, write_half, app).await;
    }

    match method.as_str() {
        "GET" | "HEAD" => http::serve(&mut write_half, &app, &path, method == "HEAD").await,
        _ => {
            write_half
                .write_all(
                    b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 19\r\n\
                      Allow: GET, HEAD\r\nConnection: close\r\n\r\nmethod not allowed\n",
                )
                .await?;
            write_half.flush().await
        }
    }
}

enum Frame {
    Message(Op, Vec<u8>),
    Closed,
}

/// One socket: a reader task feeds parsed frames, this task owns the writer and
/// forwards room traffic in both directions.
async fn session(
    reader: BufReader<OwnedReadHalf>,
    rest: Vec<u8>,
    mut writer: OwnedWriteHalf,
    app: App,
) -> std::io::Result<()> {
    let conn = app.conn.fetch_add(1, Ordering::Relaxed);
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let (frame_tx, mut frame_rx) = mpsc::unbounded_channel::<Frame>();

    tokio::spawn(async move {
        let mut reader = reader;
        let mut framer = Framer::new();
        if !rest.is_empty() {
            framer.push(&rest);
        }
        let mut chunk = [0u8; READ_CHUNK];
        loop {
            match framer.next_message() {
                Ok(Some((op, payload))) => {
                    if frame_tx.send(Frame::Message(op, payload)).is_err() {
                        return;
                    }
                    continue;
                }
                Ok(None) => {}
                Err(_) => {
                    let _ = frame_tx.send(Frame::Closed);
                    return;
                }
            }
            match reader.read(&mut chunk).await {
                Ok(0) => {
                    let _ = frame_tx.send(Frame::Closed);
                    return;
                }
                Ok(read) => framer.push(&chunk[..read]),
                Err(_) => {
                    let _ = frame_tx.send(Frame::Closed);
                    return;
                }
            }
        }
    });

    loop {
        tokio::select! {
            frame = frame_rx.recv() => {
                let Some(frame) = frame else { break };
                match frame {
                    Frame::Closed => break,
                    Frame::Message(op, payload) => match op {
                        Op::Text | Op::Binary => {
                            let text = String::from_utf8_lossy(&payload).to_string();
                            match serde_json::from_str::<ClientMsg>(&text) {
                                Ok(ClientMsg::Join { room, name, lang, amount }) => {
                                    let _ = app.hub.send(HubMsg::Join {
                                        conn,
                                        room,
                                        name,
                                        lang,
                                        amount,
                                        tx: out_tx.clone(),
                                    });
                                }
                                Ok(ClientMsg::Leave) => break,
                                Ok(other) => {
                                    let _ = app.hub.send(HubMsg::Command { conn, msg: other });
                                }
                                Err(_) => {}
                            }
                        }
                        Op::Close => break,
                        Op::Ping => {
                            let _ = out_tx.send(ws::encode(&payload, 0x0A));
                        }
                        _ => {}
                    },
                }
            }
            outbound = out_rx.recv() => {
                let Some(bytes) = outbound else { break };
                if writer.write_all(&bytes).await.is_err() {
                    break;
                }
            }
        }
    }

    let _ = app.hub.send(HubMsg::Gone { conn });
    let _ = writer.shutdown().await;
    Ok(())
}

pub(crate) async fn reply(
    writer: &mut OwnedWriteHalf,
    status: u16,
    body: &str,
) -> std::io::Result<()> {
    let reason = match status {
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        429 => "Too Many Requests",
        _ => "OK",
    };
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain; charset=utf-8\r\n\
         Content-Length: {}\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n{body}",
        body.len()
    );
    writer.write_all(response.as_bytes()).await?;
    writer.flush().await
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}
