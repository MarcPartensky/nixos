//! typer-race: terminal client for typer race rooms, same room code and word
//! stream as the browser.
//!
//!     typer-race                    create a room and print its code
//!     typer-race --room ABCD        join room ABCD
//!     typer-race --name marc --time 60
//!     typer-race --url ws://127.0.0.1:9146/ws
//!     typer-race --probe            headless: join, play, print the ranking
//!
//! Without `--url` it joins the public rooms at
//! `wss://typer.marcpartensky.com/ws` (TLS in-process, own trust store).
//!
//! Keys: letters and space type, backspace corrects, r readies (lobby) or asks
//! for a rematch (final ranking), t cycles the duration, l the word list,
//! q quits, Esc always quits.

mod app;
mod client;
mod ui;

use std::io;
use std::time::{Duration, Instant};

use ratatui::backend::CrosstermBackend;
use ratatui::crossterm::event::{self, Event, KeyEventKind};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{self, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::Terminal;

use app::App;
use client::Client;

const USAGE: &str = "typer-race [--room ABCD] [--name NAME] [--lang english200|english1000|\
french200|french1000] [--time 15|30|60|120] [--ui fr|en] [--url ws(s)://host/ws] [--probe] \
[--wait-for N]";

struct Options {
    url: String,
    room: String,
    name: String,
    lang: String,
    amount: u32,
    ui: &'static str,
    probe: bool,
    wait_for: usize,
}

fn main() {
    if let Err(err) = run() {
        eprintln!("typer-race: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let options = parse_args()?;
    let client = Client::connect(&options.url)?;
    let mut app = App::new(
        client,
        options.name.clone(),
        options.lang.clone(),
        options.amount,
        options.ui,
    );
    app.join(&options.room)?;

    if options.probe {
        return probe(&mut app, options.wait_for);
    }

    let mut stdout = io::stdout();
    terminal::enable_raw_mode().map_err(|err| err.to_string())?;
    execute!(
        stdout,
        EnterAlternateScreen,
        terminal::Clear(terminal::ClearType::All)
    )
    .map_err(|err| err.to_string())?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend).map_err(|err| err.to_string())?;
    let _ = terminal.hide_cursor();

    let result = event_loop(&mut terminal, &mut app);

    terminal::disable_raw_mode().ok();
    let _ = execute!(terminal.backend_mut(), LeaveAlternateScreen);
    let _ = terminal.show_cursor();
    result
}

fn event_loop(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    app: &mut App,
) -> Result<(), String> {
    let mut last_draw = Instant::now() - Duration::from_secs(1);
    while !app.quit {
        app.tick()?;
        if event::poll(Duration::from_millis(16)).map_err(|err| err.to_string())? {
            if let Event::Key(key) = event::read().map_err(|err| err.to_string())? {
                if key.kind == KeyEventKind::Press && !app.handle_key(key) {
                    app.quit = true;
                }
            }
        }
        if last_draw.elapsed() >= Duration::from_millis(50) {
            terminal
                .draw(|frame| ui::draw(frame, app))
                .map_err(|err| err.to_string())?;
            last_draw = Instant::now();
        }
    }
    Ok(())
}

/// Headless smoke test: joins the room, plays the whole stream and prints the
/// ranking. Used to prove the protocol without a terminal. `wait_for` delays the
/// ready signal until the room holds that many players, so a two-process test
/// can start together.
fn probe(app: &mut App, wait_for: usize) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(180);
    let mut last_phase = String::new();
    let mut ready_sent = false;
    let mut typed = false;

    while Instant::now() < deadline {
        app.pump()?;
        let phase = app.phase().unwrap_or("lobby").to_string();
        if phase != last_phase {
            println!(
                "probe: room={} phase={} players={} words={}",
                app.room,
                phase,
                app.board().len(),
                app.run.words.len()
            );
            last_phase = phase.clone();
            if phase == "race" && !typed {
                typed = true;
                let words = app.run.words.clone();
                for word in &words {
                    for ch in word.chars() {
                        app.run.feed(ch);
                    }
                    app.run.feed(' ');
                }
                app.send_progress()?;
                app.send_done()?;
                println!(
                    "probe: typed {} words, local wpm={} acc={:.1}",
                    words.len(),
                    app.run.wpm(),
                    app.run.acc()
                );
            }
        }
        if phase == "lobby" && !ready_sent && app.room.len() == 4 && app.board().len() >= wait_for {
            app.set_ready(true)?;
            ready_sent = true;
            println!("probe: ready sent");
            // A race now needs two players; the probe is usually alone in the
            // room it just created, so it starts the round as the host.
            if wait_for <= 1 && app.is_host() {
                app.start()?;
                println!("probe: start sent (host, alone)");
            }
        }
        if phase == "done" {
            for row in app.board() {
                println!(
                    "probe: rank={} name={} wpm={} chars={} acc={}",
                    row["rank"], row["name"], row["wpm"], row["chars"], row["acc"]
                );
            }
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err("probe timed out".to_string())
}

fn parse_args() -> Result<Options, String> {
    let mut url = String::from("wss://typer.marcpartensky.com/ws");
    let mut room = String::new();
    let mut name = std::env::var("TYPER_NAME")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_else(|_| "guest".to_string());
    let mut lang = String::new();
    let mut amount = 30u32;
    let french = std::env::var("LANG")
        .map(|value| value.to_lowercase().starts_with("fr"))
        .unwrap_or(false);
    let mut ui: &'static str = if french { "fr" } else { "en" };
    let mut probe = false;
    let mut wait_for = 1usize;

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--url" => {
                i += 1;
                url = args.get(i).ok_or("--url needs a value")?.clone();
            }
            "--room" => {
                i += 1;
                room = args
                    .get(i)
                    .ok_or("--room needs a code")?
                    .trim()
                    .to_uppercase();
            }
            "--name" => {
                i += 1;
                name = args.get(i).ok_or("--name needs a value")?.clone();
            }
            "--lang" => {
                i += 1;
                lang = args.get(i).ok_or("--lang needs a value")?.clone();
            }
            "--time" => {
                i += 1;
                amount = args
                    .get(i)
                    .ok_or("--time needs a number")?
                    .parse()
                    .map_err(|_| "--time needs a number")?;
            }
            "--ui" => {
                i += 1;
                ui = match args.get(i).map(String::as_str) {
                    Some("fr") => "fr",
                    Some("en") => "en",
                    _ => return Err("--ui is fr or en".to_string()),
                };
            }
            "--probe" => probe = true,
            "--wait-for" => {
                i += 1;
                wait_for = args
                    .get(i)
                    .ok_or("--wait-for needs a number")?
                    .parse()
                    .map_err(|_| "--wait-for needs a number")?;
            }
            "-h" | "--help" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument: {other}\n{USAGE}")),
        }
        i += 1;
    }

    if lang.is_empty() {
        lang = typer_core::default_lang(ui).to_string();
    }
    if !typer_core::LANGS.iter().any(|(id, _)| *id == lang) {
        return Err(format!("unknown word list: {lang}"));
    }
    if !typer_core::AMOUNTS.contains(&amount) {
        return Err("--time is 15, 30, 60 or 120".to_string());
    }

    Ok(Options {
        url,
        room,
        name,
        lang,
        amount,
        ui,
        probe,
        wait_for,
    })
}
