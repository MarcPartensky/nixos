# Winnie out of the host config (deploy/winnie)

Winnie has not been in tower's NixOS config since 13/11/2026: the module read
the project flake with `builtins.getFlake`, which forced Nix to hash the 16 GB
working tree on every evaluation (863 s) and made `--impure` mandatory. The
trigger of the exit is documented in `services/default.nix` (import `./winnie`
commented out).

These three units replace the removed root units:

| unit | role | port | public domain (newt/Pangolin) |
| --- | --- | --- | --- |
| `winnie-backend.service` | Rust/Axum backend | 127.0.0.1:8787 | api.winnie.marcpartensky.com |
| `winnie-frontend.service` | static front (`app/dist`) | 127.0.0.1:8888 | winnie.marcpartensky.com |
| `winnie-dev.service` | Vite + HMR on the source | 0.0.0.0:8080 | dev.winnie.marcpartensky.com |

They run in **`hermes`'s user systemd** (linger active), not in the system
systemd: no root, no `nixos-rebuild`. Installation:

```sh
mkdir -p ~/.config/systemd/user/default.target.wants
for u in winnie-backend winnie-frontend winnie-dev; do
  ln -sfn /home/marc/git/nixos/deploy/winnie/$u.service ~/.config/systemd/user/$u.service
  ln -sfn /home/marc/git/nixos/deploy/winnie/$u.service \
    ~/.config/systemd/user/default.target.wants/$u.service
done
systemctl --user daemon-reload
systemctl --user start winnie-backend winnie-frontend winnie-dev
```

## Secrets and state

`/var/lib/hermes/winnie/` (0700 hermes) carries the environment files, all
optional except the first:

- `jwt.env`: `JWT_SECRET` (mandatory; without it the binary signs with a public
  dev default)
- `s3.env`: `S3_ENDPOINT`, `S3_BUCKET=winnie-media`, `S3_ACCESS_KEY`,
  `S3_SECRET_KEY`, `S3_REGION`, `S3_FORCE_PATH_STYLE` (without it `/media/*`
  answers 503 and the feed's photos are missing)
- `oidc.env`: `OIDC_*` (Zitadel login; without it `/auth/methods` reports
  `zitadel: false`)
- `openrouter.env`: `OPENROUTER_API_KEY` (chat + ingest)
- `stripe.env`: `STRIPE_*` (checkout)

`sws/` is a GC-safe link to `static-web-server`
(`nix build nixpkgs#static-web-server --out-link .../winnie/sws`), `sops/`
likewise for the sops binary that was used to restore `oidc.env` (ed25519 host
key, root).

These secrets come from the old `/var/lib/winnie/*.env` files (uid/gid `winnie`
orphaned since 13/11, 0750) and from the sops secret `oidc_env` of
`secrets/winnie.yml`, copied once by
`/var/lib/hermes/winnie/restore-secrets.sh` run as root through
`hermes-request`; log: `/var/lib/hermes/winnie/restore-secrets.log`.

## Redeploying

- Static front: `cd /home/marc/git/winnie/app && npm run build` then
  `systemctl --user restart winnie-frontend` (the prod domain serves `dist`).
- Dev: nothing to do, Vite serves the source (`dev.winnie...`), HMR active.
- Backend: `cargo build --release` in `/home/marc/git/winnie/backend` then
  `systemctl --user restart winnie-backend`.
- Nightly ingest: `winnie-ingest-nightly.service` + `.timer` now live HERE
  (added 17/11/2026). The timer fires at 03:00 (moved up from 01:00 on
  25/11/2026: 01:00 collided with marc's Hermes work on tower) and the binary
  moves itself out of the window. Redeploying an ingest binary =
  `cd /home/marc/git/winnie/ingest && cargo build --release` then
  `systemctl --user restart winnie-ingest-nightly.timer` (the timer does not
  need to be stopped: the binary is re-read on every trigger).

## Not migrated

`winnie-calories`, `winnie-hours-refresh` and `winnie-gmaps-scrape` are NOT
taken over here: their system units were removed on 17/11/2026 because they only
carried CPU overrides without ExecStart (the NixOS module that defined them had
been removed). They no longer run at all; take them over here (same shape as the
nightly ingest) the day their binaries are rebuilt. The Postgres/schema
provisioning is not taken over either: the `winnie` database and its schema
still exist.
