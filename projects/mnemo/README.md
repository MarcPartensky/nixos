# mnemo — the retention engine

Reads Marc's Hermes conversations, scores them on the same axes the podcast
queue already uses, pulls out the points he did not understand, writes an
explanation sheet for each one, and feeds two consumers: the podcast pipeline
(which turns a sheet into an episode on Audiobookshelf) and the typing drill on
`typer.marcpartensky.com`.

It answers one question — **which of my conversations mattered, and what did I
fail to understand in them?** — and it writes nothing back into Hermes.

```
Hermes state.db ──read-only──▶ mnemo ──score + gaps──▶ explanation sheet
                                 │                        │
                                 │                        ├──▶ podcast hub :8095 ──▶ episode
                                 └──typing list──────────▶└──▶ typer.marcpartensky.com
```

## What it does, step by step

1. **Reads** `~/.hermes/state.db` in `SQLITE_OPEN_READ_ONLY`. No write, ever.
   Conversations that Hermes compacted keep only their summary; that summary is
   scored as a proxy so "all my conversations" really means all of them.
2. **Scores** each one with the same grid as `score_queue.py`: `matiere`
   (substance), `ignorance` (what was not understood), `points` (number of
   ideas), `importance`, `focus`, plus `priorite`, the single number everything
   sorts on.
3. **Extracts the gaps**: the concepts Marc asked about, corrected, or never
   got, quoted from the conversation.
4. **Writes the sheet**: 400 to 600 words, in French, in a fixed shape — his
   question, the correct model, a number to anchor it, what to remember, and a
   self-test. It is what he would have needed to read instead of re-reading the
   whole conversation.
5. **Publishes**: enqueues the conversation in the podcast hub (the hub owns
   episode generation, notebooks and Audiobookshelf — mnemo does not), and
   writes the vocabulary the drill should make him type.

## Run it

```sh
# everything local, no database: Store::Dry is a no-op
MNEMO_SESSIONS_DB=~/.hermes/state.db \
MNEMO_LLM_URL=http://100.64.0.4:8094/v1 MNEMO_LLM_MODEL=free-pool \
cargo run -- scan --limit 5

cargo run -- sessions --limit 20   # what the reader sees, before any LLM call
cargo run -- backlog               # the queue of scored conversations
cargo run -- publish <session-id>  # score one, write its sheet, enqueue it
cargo run -- serve                 # the HTTP + MCP surface
```

Build on the **laptop**, never on tower:

```sh
nix build .#image      # -> result, an OCI tarball for the k3s node
just ship              # build, then copy the tarball to tower
```

## Configuration

Everything is an environment variable; there is no config file.

| Variable | Default | Role |
| --- | --- | --- |
| `MNEMO_SESSIONS_DB` | `$HOME/.hermes/state.db` | Hermes history, opened read-only |
| `MNEMO_DB` | *(unset)* | Postgres URL; unset means dry-run, nothing is stored |
| `MNEMO_LLM_URL` | `http://100.64.0.4:8094/v1` | OpenAI-compatible endpoint |
| `MNEMO_LLM_MODEL` | `free-pool` | model alias |
| `MNEMO_LLM_KEY` / `MNEMO_LLM_KEY_FILE` | *(unset)* | bearer token, inline or from a file |
| `MNEMO_LLM_ZDR` | `0` | send `provider.zdr` so the provider keeps the request out of training |
| `MNEMO_HUB_URL` | `http://127.0.0.1:8095` | podcast hub |
| `MNEMO_HUB_TOKEN_FILE` | `$HOME/.hermes/podcast-hub-token` | `X-Hub-Token` |
| `MNEMO_BRIEF_DIR` | `$HOME/.hermes/mnemo/briefs` | the sheets, one markdown each |
| `MNEMO_TYPER_DIR` | `/var/lib/mnemo/typer-lang` | the typing list |
| `MNEMO_MIN_PRIORITY` | `8` | below this, a conversation is scored but gets no sheet |
| `MNEMO_ANALYZE_TOKENS` | `8000` | output budget per scoring call |
| `MNEMO_BRIEF_TOKENS` | `6000` | output budget per sheet |
| `MNEMO_BATCH` | `5` | conversations per scoring call |
| `MNEMO_OPEN` | `0` | `1` when a proxy already gates the service |

`MNEMO_ANALYZE_TOKENS` and `MNEMO_BRIEF_TOKENS` are generous on purpose: a
reasoning model spends most of the budget on its scratchpad before it writes
anything, and a tight limit produces a truncated answer that looks like success.

## Surfaces

- `GET /` — the status page: what was scanned, what is queued, the sheets.
- `GET /api/stats`, `GET /api/backlog`, `POST /api/scan` — the same thing as JSON.
- `POST /mcp` — JSON-RPC for Hermes: `tools/list`, `tools/call` with
  `mnemo_scan`, `mnemo_backlog`, `mnemo_stats`.
- `GET /healthz` — for the cluster and for Pangolin.

`X-Mnemo-Token` is required on `/api/*` and `/mcp` unless `MNEMO_OPEN=1`; the
token is read from `MNEMO_TOKEN_FILE` and created there on first start. Behind
Pangolin with Zitadel SSO, the pod runs with `MNEMO_OPEN=1`: the edge is the
only gate, and the port is loopback anyway.

## Deployment

`module.nix` exports a NixOS module; the pod manifest is declared through
`services.k3s.manifests`, so k3s applies it itself — no helm, no `kubectl apply`.
The pod uses `hostNetwork`, which keeps Postgres and the podcast hub on plain
`127.0.0.1` and lets Pangolin target the loopback port like every other service
on this host.

The image is built on the laptop and imported into containerd at activation from
`services.mnemo.imageFile`. Nothing compiles Rust on tower.

```nix
inputs.mnemo = { url = "path:./projects/mnemo"; inputs.nixpkgs.follows = "nixpkgs"; };
imports = [ inputs.mnemo.nixosModules.default ];
services.mnemo.enable = true;
```

Postgres: one role and one database of its own (`mnemo` / `mnemo`), schema
applied by a oneshot unit, idempotent `create table if not exists`.

## Not done yet

- The typing list lands in `MNEMO_TYPER_DIR`; `typer-server` still serves its
  word lists from its own read-only root, so it needs a `--lang-dir` override to
  pick up `/var/lib/mnemo/typer-lang`. Until then the list is generated and
  unused.
- n8n: the flow was mentioned as a maybe. Nothing here depends on it — the hub's
  own tick does the scheduling, and `mnemo scan` is a cron away.
