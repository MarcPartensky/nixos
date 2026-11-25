//! Small helpers: environment, local clock, command execution with a timeout.
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub fn now_f() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

pub fn env_s(key: &str, def: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| def.to_string())
}

pub fn env_f(key: &str, def: f64) -> f64 {
    std::env::var(key).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(def)
}

pub fn env_u(key: &str, def: u64) -> u64 {
    std::env::var(key).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(def)
}

/// local tm (honours TZ / /etc/localtime, zero timezone dependency).
pub fn local_tm(t: i64) -> libc::tm {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let tt = t as libc::time_t;
    unsafe { libc::localtime_r(&tt, &mut tm) };
    tm
}

pub fn hhmm() -> (u32, u32) {
    let tm = local_tm(now());
    (tm.tm_hour as u32, tm.tm_min as u32)
}

/// "YYYY-MM-DD" in local time.
pub fn ymd(t: i64) -> String {
    let tm = local_tm(t);
    format!("{:04}-{:02}-{:02}", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday)
}

/// Runs a command, returns (code, stdout+stderr); hard timeout.
pub fn run_timeout(cmd: &str, args: &[String], timeout: Duration) -> (i32, String) {
    let mut child = match Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return (255, format!("spawn: {e}")),
    };
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if start.elapsed() > timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    return (124, "timeout".into());
                }
                std::thread::sleep(Duration::from_millis(15));
            }
            Err(e) => return (255, format!("wait: {e}")),
        }
    }
    // bounded stdout: a probe must never bring back megabytes
    let mut out = String::new();
    if let Some(mut s) = child.stdout.take() {
        let mut buf = vec![0u8; 65536];
        let _ = s.read(&mut buf);
        out.push_str(&String::from_utf8_lossy(&buf));
    }
    let mut err = String::new();
    if let Some(mut s) = child.stderr.take() {
        let mut buf = vec![0u8; 8192];
        let _ = s.read(&mut buf);
        err.push_str(&String::from_utf8_lossy(&buf));
    }
    let code = child.wait().map(|s| s.code().unwrap_or(255)).unwrap_or(255);
    (code, out + &err)
}

pub fn run(cmd: &str, args: &[&str], timeout_s: u64) -> (i32, String) {
    let owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();
    run_timeout(cmd, &owned, Duration::from_secs(timeout_s))
}

/// Full output of a command (useful for sqlite3, which can return > 64 K).
pub fn capture(cmd: &str, args: &[&str], timeout_s: u64) -> Option<String> {
    let child = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .ok()?;
    let (tx, rx) = mpsc::channel();
    let handle = std::thread::spawn(move || {
        let mut child = child;
        let mut s = String::new();
        if let Some(mut out) = child.stdout.take() {
            let _ = out.read_to_string(&mut s);
        }
        let _ = child.wait();
        let _ = tx.send(s);
    });
    match rx.recv_timeout(Duration::from_secs(timeout_s)) {
        Ok(s) => {
            let _ = handle.join();
            Some(s)
        }
        Err(_) => None,
    }
}

/// "key=value" lines (keys [a-z_]).
pub fn kv(text: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some((k, v)) = line.split_once('=') {
            if !k.is_empty() && k.chars().all(|c| c.is_ascii_lowercase() || c == '_') {
                out.insert(k.to_string(), v.trim().to_string());
            }
        }
    }
    out
}

pub fn read(path: &str) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

/// Atomic write (tmp + rename), permissions 0644.
pub fn write_atomic(path: &str, data: &str) {
    let tmp = format!("{path}.tmp");
    if std::fs::write(&tmp, data).is_ok() {
        let _ = std::fs::set_permissions(&tmp, std::os::unix::fs::PermissionsExt::from_mode(0o644));
        let _ = std::fs::rename(&tmp, path);
    }
}
