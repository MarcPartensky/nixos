# nixos

Marc Partensky's NixOS + Home Manager + nix-darwin configuration, one flake for every machine: `tower`, `laptop`, `deck`, the `anywhere` VPS, the Mac, and the phone (nix-on-droid).

## Machines

| Flake output | Type | Description |
|---|---|---|
| `nixosConfigurations.tower` | NixOS | Main machine (AMD, ZFS). `profiles/common` + `profiles/tower` + `services/` (all self-hosted services). |
| `nixosConfigurations.laptop` | NixOS | Laptop. `profiles/common` + `profiles/laptop` + `services/`. |
| `nixosConfigurations.deck` | NixOS | Steam Deck (via Jovian-NixOS). `profiles/deck` only, no `services/`. |
| `nixosConfigurations.anywhere` | NixOS | VPS (RackNerd): Pangolin, Traefik/Caddy, Stalwart mail, headscale. `profiles/anywhere`. |
| `nixosConfigurations.laptop-iso` / `deck-iso` | NixOS | Installer images (disko + hardware-configuration bundled). |
| `nixosConfigurations.dev` | NixOS (microvm) | Disposable dev VM, see `vms/`. Launched with `just vm`. |
| `homeConfigurations.marc` | Home Manager standalone | Marc's Linux profile (tower/laptop), **not wired** into any `nixosConfigurations` — managed independently. |
| `homeConfigurations."marc@macos"` | Home Manager | HM profile on the Mac (on top of nix-darwin). |
| `homeConfigurations."marc@deck"` | Home Manager | HM profile on the Deck. |
| `darwinConfigurations.macos` | nix-darwin | The Mac's system config. |
| `nixOnDroidConfigurations.default` | nix-on-droid | Android phone. |

`nixpkgs` = `nixos-26.05` (+ `unstable` for packages missing from 26.05, `nixpkgs-darwin`/`nix-darwin-26.05` for the Mac).

## Repo layout

```
flake.nix              every nixosConfigurations / homeConfigurations / darwinConfigurations
Justfile + .env        common commands (default HOST, HM, RUN)
profiles/<host>/       per-machine composition (imports, firewall, hostName, sops file)
  common/               base shared by tower+laptop (users, nixos modules, home-manager.users.root)
hosts/<name>/          disko.nix + hardware-configuration.nix per machine
modules/
  nixos/<name>/         unit NixOS modules (enabled = imported in profiles/common or profiles/<host>)
  home/<name>/           Home Manager modules (Linux), imported by users/marc/home.nix
  home-mac/<name>/       Mac-specific Home Manager modules
users/
  marc/                  home.nix + packages.nix (standalone profile, `just home`)
  root/                  home.nix wired via profiles/common (only HM profile inside nixosConfigurations)
  mac/, deck/            HM profiles for the other machines
services/<name>/       self-hosted services (one folder per service), registry = services/default.nix
  hermes/plugins/        Nix-managed plugins for the Hermes gateway
secrets/*.yml           sops-age encrypted secrets (see below)
vms/                    microvm.nix definitions for dev VMs
```

`services/` is only imported by `laptop` and `tower` (see `flake.nix`): `deck` and `anywhere` don't have this registry.

## Commands (Justfile)

`.env` sets the defaults: `HOST=tower`, `HM=marc`, `RUN=nixos`.

| Command | Effect |
|---|---|
| `just` | `just nixos` (via `RUN`) |
| `just nixos` | `sudo nixos-rebuild switch --impure --flake .#$HOST` |
| `just home` | `home-manager switch --flake .#$HM` (run as `marc`, not `hermes`) |
| `just mac` | `nix-darwin switch --flake .#macos` |
| `just droid` | `nix-on-droid switch --flake ~/.config/nixos#default` |
| `just vm [name=dev]` | build + launch a dev microvm (state in `~/.local/state/microvms/<name>/`) |
| `just vm-build [name=dev]` | build only, don't launch |
| `just iso` | ISO image for `$HOST-iso` |
| `just install` | disko + `nixos-install` (new machine) |
| `just ventoy <disk> [size]` | Ventoy USB stick + Nix installer |

Updating inputs: `nix flake update` before a rebuild (`--upgrade` has no effect on a flake, don't use it).

Eval check without building: `nix eval .#nixosConfigurations.$HOST.config.system.build.toplevel.drvPath --impure`.

## Secrets (sops-nix)

- `secrets/*.yml`, one file per domain (`tower.yml`, `common.yml`, `anywhere.yml`, `zitadel.yml`, `gitea.yml`, ...), encrypted with `sops` + `age` keys.
- 4 keys in `.sops.yaml`: anywhere, tower, mac, deck. `common.yml` is decryptable by every machine; each profile sets `sops.defaultSopsFile` to its dedicated file.
- Creating a **new** secret only needs the public keys already in `.sops.yaml`: `nix run nixpkgs#sops -- -e --filename-override secrets/<name>.yml --output secrets/<name>.yml <plaintext>`. Editing an **existing** file in place requires the private key (root only).

## Self-hosted services (tower/laptop)

Registry in `services/default.nix`. Active on tower:

- **Infra / networking**: `newt` (Pangolin tunnel), `autossh`, `eternal-terminal`, `adguard`, `tor`, `wayvnc`, `cage-firefox`.
- **Accounts / auth**: `zitadel` (OIDC), `vaultwarden`.
- **Cloud / files**: `nextcloud` (+ postgres), `gitea`.
- **Media**: `jellyfin`, `navidrome`, `audiobookshelf`, `radarr`/`sonarr`/`readarr`/`prowlarr`/`flaresolverr`, `qbittorrent`/`rqbit`, `media` (shared `/srv/media` dataset).
- **Matrix bridges**: `matrix` (Synapse), `matrix-whatsapp`, `matrix-signal`, `matrix-discord`, `matrix-meta`, `matrix-linkedin`.
- **Hermes agent**: `hermes` (gateway + plugins), `hermes-webui`, `hermes-dashboard`, `hermes-pocket` (mobile app backend), `discord-bot`.
- **MCP servers** (tools for Hermes): `nextcloud-mcp`, `amazon-mcp`, `firefox-mcp`, `zitadel-mcp`, `roku`, `codeberg-mcp`, `ibkr-mcp`, `meetup-mcp`, `gitea-mcp`, `arr-mcp`, `mcp-nixos`.
- **Other apps**: `jupyterhub`.
- **Disabled in the registry** (commented out, pending a fix or waiting on something): `dnscrypt`, `minio`, `stalwart-mcp` (cargoHash mismatch), `gotify`, `kanidm`, `syncserver`, `matrix-telegram` (waiting on api_id/api_hash), `vaultwarden-mcp` (missing input).

## Conventions

- Comments and commit messages in French, conventional commits format (`feat(scope): ...`, `fix(scope): ...`, `chore(scope): ...`), grouped by logical theme (not one commit per touched file).
- A module is "enabled" by being added to its registry's import list (`services/default.nix`, `profiles/common/default.nix`, `users/marc/home.nix`, ...); commented out = disabled but kept as reference.
- `home-manager.users.marc` must **never** be wired into any `nixosConfigurations`: Marc's profile stays standalone Home Manager (`just home`), only `root` goes through the NixOS module (`profiles/common`).
- The repo is edited concurrently (multiple sessions/agents): check `git status` and that no `nixos-rebuild` is already running before triggering a switch.
