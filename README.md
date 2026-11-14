# nixos

One flake for every machine I run: the home server, the laptop, the Steam Deck, a small VPS, a Mac and an Android phone. Everything is declarative: packages, services, containers, secrets, tunnel routes, and the agent that drives all of it.

The interesting part is not the desktop, it is the infrastructure: a single VPS as the only public door, a private mesh underneath, ZFS everywhere, encrypted secrets in the repo, and a few dozen self-hosted services that I actually use.

## Machines

| Flake output | Machine | Role |
|---|---|---|
| `nixosConfigurations.tower` | AMD Ryzen 7 4800H mini-PC, 62 GB RAM, 1.4 TB pool (ZFS on root via disko) | The home server. Almost every service runs here. CPU only, no GPU. |
| `nixosConfigurations.laptop` | 3060 mobile, the only CUDA machine | Local LLM endpoint (`llama-swap`) and local TTS. Pulls the nightly backup of tower. |
| `nixosConfigurations.deck` | Steam Deck (Jovian-NixOS) | Game console, plus a Windmill worker, a scheduled Monero miner and an LLM endpoint. |
| `nixosConfigurations.anywhere` | RackNerd VPS | The public entry point: Pangolin (TLS + SSO), headscale, Zitadel, Vaultwarden, Stalwart mail, observability. |
| `nixosConfigurations.laptop-iso` / `deck-iso` | | Installer images (disko + hardware configuration bundled). |
| `nixosConfigurations.dev` | microvm.nix | Disposable dev VM, see `vms/`. Launched with `just vm`. |
| `homeConfigurations.marc` | Home Manager standalone | My Linux profile on tower and laptop. Deliberately **not** wired into any `nixosConfigurations`. |
| `homeConfigurations."marc@macos"` / `"marc@deck"` | Home Manager | Profiles on the Mac and on the Deck. |
| `darwinConfigurations.macos` | nix-darwin | The Mac's system config. |
| `nixOnDroidConfigurations.default` | nix-on-droid | The Android phone, including its SSH tunnel back to the LAN. |

`nixpkgs` is pinned to `nixos-26.05`, plus `unstable` for packages missing from 26.05, and `nixpkgs-darwin` / `nix-darwin-26.05` for the Mac.

## Architecture

### One public door

`*.marcpartensky.com` is a wildcard DNS record pointing at the VPS (`anywhere`). Nothing else is reachable from the internet: tower sits behind residential NAT and opens no port to the outside.

- **Pangolin** on the VPS terminates TLS and routes by hostname to a **newt** tunnel client running on each host. Routes are declared in Nix (`services.newt.blueprint.proxy-resources.<name>`), so adding a domain is a rebuild, not a click.
- **Zitadel** is the identity provider. Where an app supports OIDC it authenticates itself (Gitea, Gotify, Immich, Wiki.js). Where it does not, Pangolin enforces SSO at the proxy level before the request ever reaches the app.
- **No ACME on tower**: the wildcard points at the VPS, so an http-01 challenge can never reach tower. Local vhosts are plain HTTP on loopback and TLS lives entirely on the VPS.

### A private network underneath

- **headscale** (self-hosted Tailscale control plane) runs on the VPS. tower, laptop, deck, the phone and the VPS are all tailnet nodes. tower advertises itself as an exit node and announces the `192.168.1.0/24` LAN, so the phone reaches the LAN from anywhere without a port forward.
- **ygg-mesh** is a second overlay (Yggdrasil, carried over Tor plus a direct LAN link) that keeps working when DNS or the tailnet is unhappy. Members: tower, anywhere, deck.
- **WireGuard `wg1`** is the older hub and spoke link to the VPS, still used for paths that predate the tailnet, notably the VPS reaching the LAN through tower.

### Storage

- ZFS on root, created by **disko**, with separate datasets for `/nix`, the home tree, media and downloads. The ARC is capped at 16 GB: on a 62 GB box an uncapped cache grew to 61 GB and pushed every build into swap (evaluation went from 90 s to 236 s under pressure).
- **zram** (25 % of RAM, zstd, priority 110) is the first swap tier, so anonymous pages are compressed in RAM before the NVMe is touched. `vm.swappiness` is lowered to 10.
- **Garage** provides S3 on loopback: build artifacts (APK, archives) and a mirror of the phone photo tree, one bucket per source. It replaced RustFS, which burned a full core at rest with no client connected.
- **atticd** is a local Nix binary cache fed by the daemon's `post-build-hook`, so a flake update or a garbage collection does not cost a recompilation of the local packages.
- **backup-pqbox** dumps the databases and the agent state, encrypts them with a post-quantum key (ML-KEM-768) and keeps three tiers (daily, weekly, manual). The producer is the laptop at 03:10; tower runs at 05:00 as a fallback and skips when a fresh archive already exists.

### Privilege and change control

- **hermes-broker** is the only path to root for the agent: a PAM password or a WebAuthn passkey, first valid proof wins, everything audited and rate limited.
- **nixos-rebuild-gated** wraps `nixos-rebuild` for both the user and the agent: it refuses `--impure` and serializes rebuilds with a lock file, because two parallel activations corrupt `/etc/passwd` permissions.
- Pure evaluation is a hard rule: no `builtins.getFlake`, no `getEnv`, no `pathExists` outside the store in any evaluated module. Anything that reads external state becomes an input of the flake.

### The agent layer

- **hermes-agent** runs as a systemd service with its own user and state directory, and serves several surfaces: the Matrix gateway, an API server, the mobile backend, a web UI and an admin dashboard. A single gateway process multiplexes profiles, so the Discord side is a separate bot process talking to that gateway over loopback.
- **MCP** (Model Context Protocol) servers give the agent its tools. Most of them are hosted in a single **mcp-host** process (8 servers, ~90 tools, 85 MB RSS) instead of one process per session, which had reached 133 processes and 1.7 GB. Servers that only speak stdio stay as declared stdio entries.
- Plugins (Matrix reactions, Gotify bridging, pane reporting) are packaged by Nix and linked into the agent profile at activation.

### Applications

Roughly grouped, all declared as modules under `services/`:

| Domain | Services |
|---|---|
| Edge and networking | `pangolin`, `newt`, `traefik`, `headscale`, `tailscale`, `ygg-mesh`, `wireguard`, `adguard` (DNS resolver, also bound on the tailnet), `tor` |
| Identity | `zitadel` (OIDC), `vaultwarden` (on the VPS), `hermes-broker` |
| Files and sync | `nextcloud` (+ Postgres, Redis, nginx), `immich` (external read-only photo library, indexing limited to a nightly window), `gitea`, `syncthing`, `photos` |
| Media | `jellyfin`, `navidrome` + `aonsoku` + `octo`, `audiobookshelf`, `radarr`/`sonarr`/`readarr`/`prowlarr`/`flaresolverr`, `qbittorrent`/`rqbit`, `go2rtc` |
| Communication | `matrix-synapse` with `mautrix` bridges (WhatsApp, Signal, Discord, Meta, LinkedIn), `stalwart` mail, `gotify` + `gotify-matrix` |
| Knowledge | `anki-sync-server` + headless `anki-mcp`, `open-notebook`, Wiki.js and a static docs comparison, `jupyterhub` |
| Small tools | `shlink` (short links) + `share-mcp` (S3 to short link to share page), `reactive-resume`, `thclaws`, `fdroid-repo`, `windmill` |
| Remote access | `rustguac` (Guacamole compatible gateway), `kasmvnc` (Plasma 6 desktop in the browser, plus a visible Chromium with CDP for browser automation), `novnc`, `rustdesk`, `ttyd` + `zellij`, `eternal-terminal` |
| Cluster | `k3s` single node, used to serve the Rancher console through a fixed ClusterIP, no port open anywhere |
| Job queue | `windmill`: server and Postgres on tower, workers on the Deck, the VPS and the laptop, all over the tailnet |

### Observability

`zabbix` server on the VPS with an agent on every machine, `uptime-kuma`, `glances` (web htop), `atop` (per process CPU with peak history), `mesh-dashboard` (tailnet nodes), `usage-dashboard` (LLM spend per model and per key), `finance-dashboard` (daily expenses), and an interactive 3D map of the whole stack (cluster, network, agent, MCP, tasks, auth, backups) fed live from systemd, sockets, Pangolin, Zitadel and the job queue.

## Repo layout

```
flake.nix              every nixosConfigurations / homeConfigurations / darwinConfigurations
Justfile + .env        common commands (default HOST, HM, RUN)
profiles/<host>/       per machine composition (imports, firewall, hostName, sops file)
  common/              base shared by tower and laptop (users, modules, home-manager.users.root)
hosts/<name>/          disko.nix + hardware-configuration.nix per machine
modules/
  nixos/<name>/        unit NixOS modules (enabled when imported by a profile)
  home/<name>/         Home Manager modules for Linux
  home-mac/<name>/     Mac specific Home Manager modules
users/                 marc/ (standalone HM profile), root/ (HM inside NixOS), mac/, deck/
services/<name>/       one folder per self-hosted service, registry in services/default.nix
  hermes/plugins/      Nix managed plugins for the agent
mcp/                   mcp-host: one process serving the hand written MCP servers
deploy/                containers moved out of the host config (podman quadlets)
secrets/*.yml          sops + age encrypted secrets
scripts/, vms/         helpers (pure eval check, photo mirror) and microvm definitions
```

`services/` is imported by `tower` and `laptop` only; `deck` and `anywhere` pick their modules one by one, because a module without an `enable` option would activate on every host that imports the registry.

## Commands

`.env` sets the defaults: `HOST=tower`, `HM=marc`, `RUN=nixos`.

| Command | Effect |
|---|---|
| `just` | `just nixos` (via `RUN`) |
| `just nixos` | `flock` + `sudo nixos-rebuild-gated switch --flake .#$HOST` (never `--impure`) |
| `just home` | `home-manager switch --flake .#$HM` (must run as `marc`) |
| `just mac` | `nix-darwin switch --flake .#macos` |
| `just droid` | `nix-on-droid switch --flake ~/.config/nixos#default` |
| `just deploy <name>` | render a container quadlet from `deploy/containers.nix` and restart it, no NixOS rebuild |
| `just mcp-deploy` | sync `mcp/modules` to the running mcp-host and restart it, no rebuild |
| `just vm [name=dev]` | build and launch a dev microvm (state in `~/.local/state/microvms/<name>/`) |
| `just iso` | ISO image for `$HOST-iso` |
| `just install`, `just ventoy <disk>` | installer paths (disko + `nixos-install`) |

Updating inputs: `nix flake update` before a rebuild (`--upgrade` does nothing on a flake).

Cheap sanity checks, no build involved:

```
nix eval .#nixosConfigurations.tower.config.system.build.toplevel.drvPath
scripts/pure-check.sh    # forbids the impure shortcuts that break evaluation
```

## Containers outside the host config

Changing an image tag or an environment variable should not cost a full evaluation of tower (90 s idle, several minutes under load). Anything that is just a container therefore lives in `deploy/containers.nix`, which no host config imports and which `just deploy <name>` renders into a podman quadlet. `migrated = true` marks the ones already removed from the host config. Routes and sops secrets stay in Nix; the quadlet only reads the rendered env file under `/run/secrets`.

## Secrets (sops-nix)

- One file per domain in `secrets/*.yml`, encrypted with `sops` and `age`.
- One age key per machine in `.sops.yaml`. `common.yml` is readable by every machine; each profile sets `sops.defaultSopsFile` to its own file.
- Creating a **new** secret file needs only the public keys already in `.sops.yaml`:

```
nix run nixpkgs#sops -- -e --filename-override secrets/<name>.yml --output secrets/<name>.yml <plaintext>
```

Editing an **existing** file in place requires the private key, and therefore runs as root on that machine.

## Conventions

- Comments and commit messages are in French, conventional commits (`feat(scope): ...`, `fix(scope): ...`), grouped by logical theme rather than one commit per file.
- A module is enabled by being added to an import list; commented out means disabled but kept as reference.
- `home-manager.users.marc` must never appear in a `nixosConfigurations`: my profile stays standalone Home Manager, only `root` goes through the NixOS module.
- The repo is edited concurrently by several sessions and agents, so rebuilds are serialized and a commit always carries an explicit path list.

## Known limits

- tower is CPU only (no CUDA, no ROCm) and runs a single 1.4 TB pool at roughly 75 % full. Memory is the real constraint: 62 GB with a 16 GB ARC cap, zram, and a disk swap that used to thrash. GPU work is delegated to the laptop.
- The VPS is a single point of failure: it carries DNS, TLS, the tunnels, the identity provider and the mail server. Losing it takes every domain down, even though tower keeps running.
- Rancher, rustguac and the Kasm desktop are useful but lightly used. Several modules (`kanidm`, `syncserver`, `minio`, `dnscrypt`, `matrix-telegram`, `waydroid`) exist and are disabled, kept as reference rather than as working features.
- There is no CI and no automated deployment: validation is `nix eval`, a dry build, then a switch, one machine at a time.
- The Deck and the Mac are rebuilt rarely, so their configurations can lag behind the shared modules.

## What a public repo exposes

Everything under `secrets/` is sops ciphertext, and no private key, token or password was ever committed (checked across the whole history). Cloning this repo grants no access to anything.

What it does disclose is the shape of the infrastructure: service inventory and versions, hostnames, internal addresses (LAN, tailnet and WireGuard ranges), local ports, the reverse proxy layout, the SSH public keys of my machines, and my email addresses. That is the usual trade off for a public infra repo: useful to read, mildly useful for reconnaissance, and largely discoverable anyway for anything exposed under a public domain.

## License

No license file yet. The configuration is published as a reference; treat it as read only for reuse, and expect paths, users and domains to be specific to my setup.
