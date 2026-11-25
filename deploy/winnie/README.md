# Winnie hors conf hote (deploy/winnie)

Winnie n'est plus dans la conf NixOS de tower depuis le 13/11/2026 : le module
lisait le flake du projet avec `builtins.getFlake`, ce qui forcait Nix a hacher
les 16 Go de l'arbre de travail a chaque evaluation (863 s) et rendait `--impure`
obligatoire. Le declencheur de la sortie est documente dans
`services/default.nix` (import `./winnie` commente).

Ces trois unites remplacent les unites root supprimees :

| unite | role | port | domaine public (newt/Pangolin) |
| --- | --- | --- | --- |
| `winnie-backend.service` | backend Rust/Axum | 127.0.0.1:8787 | api.winnie.marcpartensky.com |
| `winnie-frontend.service` | front statique (`app/dist`) | 127.0.0.1:8888 | winnie.marcpartensky.com |
| `winnie-dev.service` | Vite + HMR sur la source | 0.0.0.0:8080 | dev.winnie.marcpartensky.com |

Elles tournent dans le **systemd utilisateur de `hermes`** (linger actif), pas
dans systemd systeme : pas de root, pas de `nixos-rebuild`. Installation :

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

## Secrets et etat

`/var/lib/hermes/winnie/` (0700 hermes) porte les fichiers d'environnement, tous
optionnels sauf le premier :

- `jwt.env` : `JWT_SECRET` (obligatoire ; sans lui le binaire signe avec un
  defaut de dev public)
- `s3.env` : `S3_ENDPOINT`, `S3_BUCKET=winnie-media`, `S3_ACCESS_KEY`,
  `S3_SECRET_KEY`, `S3_REGION`, `S3_FORCE_PATH_STYLE` (sans lui `/media/*`
  repond 503 et les photos du feed sont absentes)
- `oidc.env` : `OIDC_*` (login Zitadel ; sans lui `/auth/methods` annonce
  `zitadel: false`)
- `openrouter.env` : `OPENROUTER_API_KEY` (chat + ingest)
- `stripe.env` : `STRIPE_*` (checkout)

`sws/` est un lien GC-safe vers `static-web-server`
(`nix build nixpkgs#static-web-server --out-link .../winnie/sws`), `sops/` de
meme pour le binaire sops qui a servi a restaurer `oidc.env` (cle d'hote
ed25519, root).

Ces secrets viennent des anciens fichiers `/var/lib/winnie/*.env` (uid/gid
`winnie` orphelins depuis le 13/11, 0750) et du secret sops `oidc_env` de
`secrets/winnie.yml`, copies une fois par
`/var/lib/hermes/winnie/restore-secrets.sh` execute en root via
`hermes-request` ; journal : `/var/lib/hermes/winnie/restore-secrets.log`.

## Redeployer

- Front statique : `cd /home/marc/git/winnie/app && npm run build` puis
  `systemctl --user restart winnie-frontend` (le domaine prod sert `dist`).
- Dev : rien a faire, Vite sert la source (`dev.winnie...`), HMR actif.
- Backend : `cargo build --release` dans `/home/marc/git/winnie/backend` puis
  `systemctl --user restart winnie-backend`.
- Ingest nocturne : `winnie-ingest-nightly.service` + `.timer` vivent
  desormais ICI (ajoutes le 17/11/2026). Le timer declenche a 03:00 (avance
  depuis 01:00 le 25/11/2026 : 01:00 entrait en collision avec le travail
  Hermes de marc sur tower) et le
  binaire sort seul hors fenetre. Redeployer un binaire d'ingest =
  `cd /home/marc/git/winnie/ingest && cargo build --release` puis
  `systemctl --user restart winnie-ingest-nightly.timer` (le timer n'a pas
  besoin d'etre arrete : le binaire est relu a chaque declenchement).

## Non migre

`winnie-calories`, `winnie-hours-refresh` et `winnie-gmaps-scrape` ne sont PAS
repris ici : leurs unites systeme ont ete supprimees le 17/11/2026 parce
qu'elles ne portaient plus que des overrides CPU sans ExecStart (le module
NixOS qui les definissait avait ete retire). Elles ne tournent plus du tout ;
les reprendre ici (meme forme que l'ingest nocturne) le jour ou leurs binaires
seront reconstruits. Le provisioning Postgres/schema n'est pas non plus repris :
la base `winnie` et son schema existent toujours.
