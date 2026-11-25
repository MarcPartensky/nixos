//! The terminal screen: Catppuccin Mocha, one word stream, one ranking.

use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;
use serde_json::Value;

use typer_core::lang_label;

use crate::app::App;

const LAVENDER: Color = Color::Rgb(180, 190, 254);
const GREEN: Color = Color::Rgb(166, 227, 161);
const RED: Color = Color::Rgb(243, 139, 168);
const OVERLAY: Color = Color::Rgb(127, 132, 156);
const TEXT: Color = Color::Rgb(205, 214, 244);
const MAUVE: Color = Color::Rgb(203, 166, 247);
const CRUST: Color = Color::Rgb(30, 30, 46);

const FR: &[(&str, &str)] = &[
    ("lobby", "salon"),
    ("ready", "prêt"),
    ("notready", "pas prêt"),
    ("waiting", "en attente des autres"),
    ("countdown", "départ dans"),
    ("racing", "en course"),
    ("done", "terminé"),
    ("rank", "classement"),
    ("you", "toi"),
    ("host", "hôte"),
    ("room", "salle"),
    ("share", "lien"),
    ("lost", "connexion perdue"),
    ("hint.lobby", "r prêt · t durée · l liste · q quitter"),
    ("hint.race", "tape · échap quitter"),
    ("hint.done", "r revanche · q quitter"),
    ("wpm", "mots/min"),
    ("acc", "préc"),
    ("errors", "erreurs"),
    ("left", "restant"),
    ("words", "mots"),
    ("players", "joueurs"),
    ("alone", "seul dans la salle · partage le lien"),
    ("readies", "prêts"),
    ("name", "nom"),
    ("error", "erreur"),
];

const EN: &[(&str, &str)] = &[
    ("lobby", "lobby"),
    ("ready", "ready"),
    ("notready", "not ready"),
    ("waiting", "waiting for the others"),
    ("countdown", "starting in"),
    ("racing", "racing"),
    ("done", "finished"),
    ("rank", "ranking"),
    ("you", "you"),
    ("host", "host"),
    ("room", "room"),
    ("share", "link"),
    ("lost", "connection lost"),
    ("hint.lobby", "r ready · t duration · l word list · q quit"),
    ("hint.race", "type · esc quit"),
    ("hint.done", "r rematch · q quit"),
    ("wpm", "wpm"),
    ("acc", "acc"),
    ("errors", "errors"),
    ("left", "left"),
    ("words", "words"),
    ("players", "players"),
    ("alone", "alone in this room · share the link"),
    ("readies", "ready"),
    ("name", "name"),
    ("error", "error"),
];

pub fn t<'a>(ui: &str, key: &'a str) -> &'a str {
    let table = if ui == "fr" { FR } else { EN };
    table
        .iter()
        .find(|(name, _)| *name == key)
        .map(|(_, label)| *label)
        .unwrap_or(key)
}

pub fn draw(frame: &mut Frame, app: &App) {
    let area = frame.area();
    let phase = app.phase().unwrap_or("lobby");
    let players = app.board();
    let reserved = players.len().min(if phase == "lobby" || phase == "done" {
        8
    } else {
        6
    });
    let extra = match phase {
        "lobby" => 2,
        "countdown" => 1,
        "done" => 1,
        _ => 0,
    };

    let chunks = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(3),
        Constraint::Length(extra),
        Constraint::Length(reserved as u16),
        Constraint::Length(1),
    ])
    .split(area);

    header(frame, app, chunks[0], phase);
    hud(frame, app, chunks[1], phase);
    words(frame, app, chunks[2]);

    match phase {
        "lobby" => lobby(frame, app, chunks[3]),
        "countdown" => frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::raw(" "),
                Span::styled(
                    format!(
                        "{} {}…",
                        t(app.ui, "countdown"),
                        app.state
                            .as_ref()
                            .and_then(|s| s["startsIn"].as_f64())
                            .unwrap_or(1.0) as i64
                    ),
                    Style::default().fg(MAUVE).add_modifier(Modifier::BOLD),
                ),
            ])),
            chunks[3],
        ),
        "done" => frame.render_widget(
            Paragraph::new(Span::styled(
                format!(" {}", t(app.ui, "rank")),
                Style::default().fg(MAUVE).add_modifier(Modifier::BOLD),
            )),
            chunks[3],
        ),
        _ => {}
    }

    board(frame, app, chunks[4], &players, phase == "lobby");
    footer(frame, app, chunks[5], phase);
}

fn header(frame: &mut Frame, app: &App, area: Rect, phase: &str) {
    let columns = Layout::horizontal([Constraint::Min(20), Constraint::Length(24)]).split(area);
    let room = if app.room.is_empty() {
        "····".to_string()
    } else {
        app.room.clone()
    };
    let left = Line::from(vec![
        Span::styled(
            " typer-race ",
            Style::default()
                .fg(CRUST)
                .bg(LAVENDER)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" "),
        Span::styled(room, Style::default().fg(TEXT).add_modifier(Modifier::BOLD)),
    ]);
    frame.render_widget(Paragraph::new(left), columns[0]);

    let status = t(app.ui, phase);
    let clock = match phase {
        "countdown" => format!(
            " {}",
            app.state
                .as_ref()
                .and_then(|s| s["startsIn"].as_f64())
                .unwrap_or(1.0) as i64
        ),
        "race" => format!(
            " {}s",
            app.state
                .as_ref()
                .and_then(|s| s["endsIn"].as_f64())
                .unwrap_or(0.0) as i64
        ),
        _ => String::new(),
    };
    let right = Line::from(Span::styled(
        format!("{status}{clock} "),
        Style::default().fg(MAUVE),
    ));
    frame.render_widget(
        Paragraph::new(right).alignment(ratatui::layout::Alignment::Right),
        columns[1],
    );
}

fn hud(frame: &mut Frame, app: &App, area: Rect, phase: &str) {
    let mine = app.me_player();
    let live = phase == "race" || phase == "done";
    let wpm = if live {
        mine.and_then(|me| me["wpm"].as_i64()).unwrap_or(0)
    } else {
        app.run.wpm() as i64
    };
    let acc = if live {
        mine.and_then(|me| me["acc"].as_f64()).unwrap_or(100.0)
    } else {
        app.run.acc()
    };
    let left = Line::from(vec![
        Span::raw(" "),
        Span::styled(
            format!("{wpm}"),
            Style::default().fg(TEXT).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(" {}", t(app.ui, "wpm")),
            Style::default().fg(OVERLAY),
        ),
        Span::raw("   "),
        Span::styled(format!("{acc:.0}%"), Style::default().fg(GREEN)),
        Span::styled(
            format!(" {}", t(app.ui, "acc")),
            Style::default().fg(OVERLAY),
        ),
        Span::raw("   "),
        Span::styled(
            format!("{}", app.run.errors),
            Style::default().fg(if app.run.errors == 0 { GREEN } else { RED }),
        ),
        Span::styled(
            format!(" {}", t(app.ui, "errors")),
            Style::default().fg(OVERLAY),
        ),
    ]);
    frame.render_widget(Paragraph::new(left), area);

    let config = format!(
        "{} · {}s · {} ",
        lang_label(&app.lang),
        app.amount,
        app.name
    );
    frame.render_widget(
        Paragraph::new(Span::styled(config, Style::default().fg(OVERLAY)))
            .alignment(ratatui::layout::Alignment::Right),
        area,
    );
}

fn lobby(frame: &mut Frame, app: &App, area: Rect) {
    let rows = Layout::vertical([Constraint::Length(1), Constraint::Length(1)]).split(area);
    let players = app.board();
    let total = players.len();
    let readies = players
        .iter()
        .filter(|p| p["ready"].as_bool().unwrap_or(false))
        .count();
    // "2 players · ready 1/2": without the count a lone player cannot tell a
    // friend who never joined from a friend who is still thinking about it.
    // Alone, say it: that is the difference between "waiting" and "nobody is
    // coming through this code".
    let status = if total <= 1 {
        format!(" {}", t(app.ui, "alone"))
    } else {
        format!(
            " {} {} · {} {}/{}",
            total,
            t(app.ui, "players"),
            t(app.ui, "readies"),
            readies,
            total
        )
    };
    frame.render_widget(
        Paragraph::new(Span::styled(status, Style::default().fg(MAUVE))),
        rows[0],
    );
    // No room code yet (join still in flight): the link would be truncated to
    // `#room=`, which is not shareable.
    if !app.room.is_empty() {
        let link = http_link(app.client.url(), &app.room);
        frame.render_widget(
            Paragraph::new(Span::styled(
                format!(" {}: {link}", t(app.ui, "share")),
                Style::default().fg(OVERLAY),
            )),
            rows[1],
        );
    }
}

fn board(frame: &mut Frame, app: &App, area: Rect, players: &[Value], lobby: bool) {
    if players.is_empty() {
        return;
    }
    let top = players
        .iter()
        .map(|player| player["chars"].as_i64().unwrap_or(0))
        .max()
        .unwrap_or(1)
        .max(1);
    let lines: Vec<Line> = players
        .iter()
        .enumerate()
        .map(|(index, player)| {
            let mine = player["id"].as_str() == app.me.as_deref();
            let is_host = app
                .state
                .as_ref()
                .map(|state| player["id"].as_str() == state["host"].as_str())
                .unwrap_or(false);
            let ready = player["ready"].as_bool().unwrap_or(false);
            let mut tags = Vec::new();
            if mine {
                tags.push(t(app.ui, "you"));
            }
            if is_host {
                tags.push(t(app.ui, "host"));
            }
            let suffix = if tags.is_empty() {
                String::new()
            } else {
                format!(" ({})", tags.join(", "))
            };
            let name: String = player["name"]
                .as_str()
                .unwrap_or("?")
                .chars()
                .take(14)
                .collect();
            let style = if mine {
                Style::default().fg(LAVENDER).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(TEXT)
            };
            // In the lobby the race columns (wpm, bar, accuracy) are all
            // zero; who is here and who pressed ready is the only thing worth
            // showing, one line per player.
            if lobby {
                return Line::from(vec![
                    Span::styled(format!(" {:>2} ", index + 1), style),
                    Span::styled(
                        if ready { "✓ " } else { "· " },
                        Style::default().fg(if ready { GREEN } else { OVERLAY }),
                    ),
                    Span::styled(format!("{:<14}{:<18}", name, suffix), style),
                    Span::styled(
                        t(app.ui, if ready { "ready" } else { "notready" }),
                        Style::default().fg(if ready { GREEN } else { OVERLAY }),
                    ),
                ]);
            }
            let bar_width = 24usize;
            let filled = (bar_width as i64 * player["chars"].as_i64().unwrap_or(0)) / top;
            let filled = filled.clamp(0, bar_width as i64) as usize;
            let bar = "#".repeat(filled) + &"-".repeat(bar_width - filled);
            Line::from(vec![
                Span::styled(
                    format!(" {:>2} {:<14}{:<10} ", index + 1, name, suffix),
                    style,
                ),
                Span::styled(
                    format!("{:>4} ", player["wpm"].as_i64().unwrap_or(0)),
                    Style::default().fg(TEXT),
                ),
                Span::styled(bar, Style::default().fg(OVERLAY)),
                Span::styled(
                    format!(" {:>3.0}%", player["acc"].as_f64().unwrap_or(0.0)),
                    Style::default().fg(GREEN),
                ),
            ])
        })
        .collect();
    frame.render_widget(Paragraph::new(lines), area);
}

fn footer(frame: &mut Frame, app: &App, area: Rect, phase: &str) {
    let key = match phase {
        "race" => "hint.race",
        "done" => "hint.done",
        _ => "hint.lobby",
    };
    frame.render_widget(
        Paragraph::new(Span::styled(
            format!(" {}", t(app.ui, key)),
            Style::default().fg(OVERLAY),
        )),
        area,
    );
    if !app.error.is_empty() {
        frame.render_widget(
            Paragraph::new(Span::styled(
                format!("{} ", app.error),
                Style::default().fg(RED).add_modifier(Modifier::BOLD),
            ))
            .alignment(ratatui::layout::Alignment::Right),
            area,
        );
    }
}

fn words(frame: &mut Frame, app: &App, area: Rect) {
    if app.run.words.is_empty() {
        let waiting = Line::from(Span::styled(
            format!(" {}", t(app.ui, "waiting")),
            Style::default().fg(OVERLAY).add_modifier(Modifier::DIM),
        ));
        frame.render_widget(Paragraph::new(waiting), area);
        return;
    }
    let width = area.width.saturating_sub(1) as usize;
    let height = area.height as usize;
    frame.render_widget(Paragraph::new(stream_lines(app, width, height)), area);
}

fn stream_lines(app: &App, width: usize, height: usize) -> Vec<Line<'static>> {
    let rows = wrap(&app.run.words, width.max(10));
    if rows.is_empty() {
        return Vec::new();
    }
    let active = rows
        .iter()
        .position(|row| row.contains(&app.run.index))
        .unwrap_or(rows.len() - 1);
    let start = active.saturating_sub(height.saturating_sub(1) / 2);
    let mut out = Vec::new();
    for row in rows.iter().skip(start).take(height) {
        let mut spans: Vec<Span<'static>> = Vec::new();
        for (position, index) in row.iter().enumerate() {
            if position > 0 {
                spans.push(Span::raw(" "));
            }
            spans.extend(word_cells(app, *index));
        }
        out.push(Line::from(spans));
    }
    out
}

fn word_cells(app: &App, index: usize) -> Vec<Span<'static>> {
    let Some(word) = app.run.words.get(index) else {
        return Vec::new();
    };
    let typed: Vec<char> = app
        .run
        .typed
        .get(index)
        .map(|text| text.chars().collect())
        .unwrap_or_default();
    let target: Vec<char> = word.chars().collect();
    let active = index == app.run.index && !app.run.ended;
    let mut spans = Vec::with_capacity(target.len() + 2);

    for (position, expected) in target.iter().enumerate() {
        let span = match typed.get(position) {
            Some(typed) if typed == expected => {
                Span::styled(expected.to_string(), Style::default().fg(GREEN))
            }
            Some(_) => Span::styled(
                expected.to_string(),
                Style::default().fg(RED).add_modifier(Modifier::BOLD),
            ),
            None if active && position == typed.len() => Span::styled(
                expected.to_string(),
                Style::default().fg(CRUST).bg(LAVENDER),
            ),
            None => Span::styled(expected.to_string(), Style::default().fg(OVERLAY)),
        };
        spans.push(span);
    }
    for extra in typed.iter().skip(target.len()) {
        spans.push(Span::styled(extra.to_string(), Style::default().fg(RED)));
    }
    if active && typed.len() >= target.len() {
        spans.push(Span::styled(" ", Style::default().bg(LAVENDER)));
    }
    spans
}

fn wrap(words: &[String], width: usize) -> Vec<Vec<usize>> {
    let mut rows: Vec<Vec<usize>> = Vec::new();
    let mut row: Vec<usize> = Vec::new();
    let mut used = 0usize;
    for (index, word) in words.iter().enumerate() {
        let len = word.chars().count();
        if row.is_empty() {
            row.push(index);
            used = len;
        } else if used + 1 + len <= width {
            row.push(index);
            used += 1 + len;
        } else {
            rows.push(std::mem::take(&mut row));
            row.push(index);
            used = len;
        }
    }
    if !row.is_empty() {
        rows.push(row);
    }
    rows
}

/// The browser link of a room: the socket URL without its `/ws` path, in its
/// HTTP form. `wss://` has to become `https://` — a browser handed
/// `wss://host/#room=ABCD` cannot navigate there.
fn http_link(url: &str, room: &str) -> String {
    let base = if let Some(rest) = url.strip_prefix("wss://") {
        format!("https://{rest}")
    } else if let Some(rest) = url.strip_prefix("ws://") {
        format!("http://{rest}")
    } else {
        url.to_string()
    };
    let base = base.split("/ws").next().unwrap_or(&base).to_string();
    format!("{base}/#room={room}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_wrap_without_splitting() {
        let words: Vec<String> = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]
            .iter()
            .map(|word| word.to_string())
            .collect();
        let rows = wrap(&words, 12);
        assert_eq!(rows[0], vec![0, 1]);
        assert!(rows.iter().flatten().count() == words.len());
    }

    #[test]
    fn links_are_http_of_the_socket_url() {
        assert_eq!(
            http_link("ws://127.0.0.1:9146/ws", "ABCD"),
            "http://127.0.0.1:9146/#room=ABCD"
        );
        // The default URL of the public server: `wss://` must lose both the
        // TLS scheme and the `/ws` path, otherwise the printed link is not
        // something a browser can open.
        assert_eq!(
            http_link("wss://typer.marcpartensky.com/ws", "ABCD"),
            "https://typer.marcpartensky.com/#room=ABCD"
        );
    }
}
