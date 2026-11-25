# typer

Typing drills in the browser, plus private race rooms you join with a link.
Lives at <https://typer.marcpartensky.com>.

```
web/                  browser app: HTML/CSS/JS, no build step, no framework
crates/core           word pools, typing run, room protocol, RFC 6455 framing
crates/server         typer-server: static files + /ws race rooms
crates/tui            typer-race: terminal client for the same rooms
package.nix           the two binaries + web/ as one derivation (callPackage)
module.nix            NixOS module, exported as nixosModules.default
flake.nix             standalone: `nix build .#`, `nix run .#`, `nix develop`
legacy/               the Python server and curses client this replaced
```

## Why this shape

*No build step for the front-end.* The browser app is three files plus word
lists. `app.js` holds the typing engine; `race.js` only speaks to `/ws`.

*One process, one port, no runtime dependency.* `typer-server` speaks HTTP/1.1
for the static files and RFC 6455 for the WebSocket on the same socket, so the
tunnel in front of it needs nothing special: `typer.marcpartensky.com -> newt
(tower) -> 127.0.0.1:9146`.

*Rooms live in RAM.* A room is four characters (`ABCD`) kept in a map, swept
after an hour of silence. Nothing to back up, nothing to leak: no account, no
cookie, no database, and the scores of solo drills never leave the browser.

## Run

```
cargo run --release -p typer-server -- --root web --port 9146
cargo run --release -p typer-race   -- --url ws://127.0.0.1:9146/ws
```

Or, without a toolchain:

```
nix run .#            # typer-server, via the flake's default package
nix develop           # cargo, rustc, clippy, rustfmt, node, python3
```

`typer-race --probe` is headless: it joins, plays the whole stream, prints the
ranking and exits non-zero on timeout. It is the protocol smoke test.

## Flake and deploy

The flake is standalone and pinned to `nixos-26.05`. The system flake
(`/home/marc/git/nixos`) carries a copy of this tree as `projects/typer` and
takes it as a **locked path input**; the module comes from here.

```nix
# /home/marc/git/nixos/flake.nix
typer = {
  url = "path:./projects/typer";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Vendoring rather than `path:/home/marc/git/typer`: the same flake is evaluated
by tower (Linux) and by the Mac (macOS), and one absolute path cannot exist on
both. The nested flake stays standalone (`nix build ./projects/typer`), and its
files must be **git-added** in the system repo, otherwise nix refuses to read
them (`Path 'projects/typer/flake.nix' is not tracked by Git`).

```nix
# /home/marc/git/nixos/profiles/tower/configuration.nix
imports = [inputs.typer.nixosModules.default];
services.typer.enable = true;
```

```nix
# /home/marc/git/nixos/users/mac/home.nix : the terminal client on the Mac
(pkgs.callPackage (inputs.typer.outPath + "/package.nix") {})
```

A path input is re-copied on every eval, so a change under `projects/typer`
lands on the next switch with no commit; `git add` in the system repo is still
required for nix to see new files, and `nix flake lock` for a **new** input
only. (An earlier absolute-path setup pinned the HEAD commit and silently
redeployed the previous build whenever the lock was not refreshed.)

The Pangolin resource `typer.marcpartensky.com` is declared in
`services/newt/default.nix` of the system flake. If it was created through the
integration API instead, the blueprint cannot adopt it: newt logs
`Resource already exists: typer.marcpartensky.com` and silently skips the whole
blueprint. Delete the resource first, then let newt recreate it.

## Joining a race

1. Open the site, pick **Course / Race**, a name, **Créer une salle**.
2. Send the link: `https://typer.marcpartensky.com/#room=ABCD`.
3. Everyone presses **Prêt**. Three-second countdown, same word stream, ranking
   at the end. Any player can start the next round.

A guest needs a browser and the link. From a terminal (no `--url`: the public
server, TLS in-process):

```
typer-race                     create a room
typer-race --room ABCD         join one
typer-race --room ABCD --name marc --time 60
typer-race --url ws://127.0.0.1:9146/ws --ui fr   # a local server
```

Keys: letters and space type, backspace corrects, `r` ready / rematch, `t`
duration and `l` word list (host, lobby), `q` quits.

## Wire protocol

One JSON object per text frame; `t` selects the message.

| client -> server | payload |
| --- | --- |
| `join` | `room` (empty creates one), `name`, `lang`, `amount` |
| `ready` | `ready` |
| `progress` | `word`, `chars`, `wpm`, `acc` (throttled by the client) |
| `done` | `word`, `chars`, `wpm`, `acc` |
| `start` | none (host, lobby only; a race needs two ready players, this starts alone) |
| `settings` | `lang`, `amount` (host, lobby only) |
| `rematch` | none (any player, once the ranking is up) |
| `leave` | none |

| server -> client | payload |
| --- | --- |
| `state` | `room`, `phase` (`lobby`/`countdown`/`race`/`done`), `host`, `you`, `lang`, `amount`, `startsIn`, `endsIn`, `words` (from the race on), `players`, `standings` |
| `error` | `badcode`, `no_room`, `room_full`, `race_started`, `server_full` |

The server owns the word stream, the start time and the ranking; clients only
report progress every 400 ms. During a race the server broadcasts the standings
twice a second. `you` is per-connection, so a client never mistakes another
player's id for its own.

Limits: 12 players per room, 200 rooms, 30 new sockets per client per minute,
8 KB per message. Everything is per-process; restarting the service drops the
open rooms.

## Testing

```
nix build .#            # sandboxed build of the package (this repo's check)
cargo test --workspace  # core protocol, framing, coders, hub
nix run .# -- --root web --port 9147   # then browse 127.0.0.1:9147
node --check web/app.js && node --check web/race.js
```

Rust is compiled on the laptop, never on tower (tower's CPU belongs to marc).
The SSH connection is multiplexed (`ControlMaster auto`, `ControlPersist`), so
one TCP session carries every build and copy.

## legacy/

`legacy/serve.py` and `legacy/tui/typer_race.py` are the Python stdlib
implementation the Rust binaries replaced, kept until the system service
definitively runs `typer-server`. They speak the same protocol; running
`python3 legacy/serve.py --root web --port 9147` is a useful cross-check.
