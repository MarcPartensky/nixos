# nixos

Configuration NixOS + Home Manager + nix-darwin de Marc Partensky, en flake unique pour toutes les machines : `tower`, `laptop`, `deck`, le VPS `anywhere`, le Mac, et le téléphone (nix-on-droid).

## Machines

| Output flake | Type | Description |
|---|---|---|
| `nixosConfigurations.tower` | NixOS | Machine principale (AMD, ZFS). `profiles/common` + `profiles/tower` + `services/` (tous les services auto-hébergés) + `protonmail-mcp`. |
| `nixosConfigurations.laptop` | NixOS | Portable. `profiles/common` + `profiles/laptop` + `services/`. |
| `nixosConfigurations.deck` | NixOS | Steam Deck (via Jovian-NixOS). `profiles/deck` seul, pas de `services/`. |
| `nixosConfigurations.anywhere` | NixOS | VPS (RackNerd) : Pangolin, Traefik/Caddy, Stalwart mail, headscale. `profiles/anywhere`. |
| `nixosConfigurations.laptop-iso` / `deck-iso` | NixOS | Images d'installation (disko + hardware-configuration inclus). |
| `nixosConfigurations.dev` | NixOS (microvm) | VM de dev jetable, voir `vms/`. Se lance avec `just vm`. |
| `homeConfigurations.marc` | Home Manager standalone | Profil Linux de marc (tower/laptop), **pas câblé** dans les `nixosConfigurations` — géré indépendamment. |
| `homeConfigurations."marc@macos"` | Home Manager | Profil HM sur le Mac (en plus de nix-darwin). |
| `homeConfigurations."marc@deck"` | Home Manager | Profil HM sur le Deck. |
| `darwinConfigurations.macos` | nix-darwin | Système du Mac. |
| `nixOnDroidConfigurations.default` | nix-on-droid | Téléphone Android. |

`nixpkgs` = `nixos-26.05` (+ `unstable` pour les paquets absents de la 26.05, `nixpkgs-darwin`/`nix-darwin-26.05` pour le Mac).

## Structure du repo

```
flake.nix              toutes les nixosConfigurations / homeConfigurations / darwinConfigurations
Justfile + .env        commandes courantes (HOST, HM, RUN par défaut)
profiles/<host>/       composition par machine (imports, firewall, hostName, sops file)
  common/               base partagée par tower+laptop (users, modules nixos, home-manager.users.root)
hosts/<name>/          disko.nix + hardware-configuration.nix par machine
modules/
  nixos/<name>/         modules système unitaires (activés = importés dans profiles/common ou profiles/<host>)
  home/<name>/           modules Home Manager (Linux), importés par users/marc/home.nix
  home-mac/<name>/       modules Home Manager spécifiques Mac
users/
  marc/                  home.nix + packages.nix (profil standalone `just home`)
  root/                  home.nix câblé via profiles/common (seul profil HM dans les nixosConfigurations)
  mac/, deck/            profils HM des autres machines
services/<name>/       services auto-hébergés (un dossier par service), registre = services/default.nix
  hermes/plugins/        plugins Nix-managed du gateway Hermes
secrets/*.yml           secrets chiffrés sops-age (voir plus bas)
vms/                    définitions de microvm.nix pour les VM de dev
```

`services/` n'est importé QUE par `laptop` et `tower` (cf. `flake.nix`) : `deck` et `anywhere` n'ont pas ce registre.

## Commandes (Justfile)

`.env` fixe les valeurs par défaut : `HOST=tower`, `HM=marc`, `RUN=nixos`.

| Commande | Effet |
|---|---|
| `just` | `just nixos` (via `RUN`) |
| `just nixos` | `sudo nixos-rebuild switch --impure --flake .#$HOST` |
| `just home` | `home-manager switch --flake .#$HM` (à lancer en tant que `marc`, pas `hermes`) |
| `just mac` | `nix-darwin switch --flake .#macos` |
| `just droid` | `nix-on-droid switch --flake ~/.config/nixos#default` |
| `just vm [nom=dev]` | build + lance une microvm de dev (état dans `~/.local/state/microvms/<nom>/`) |
| `just vm-build [nom=dev]` | build seul, sans lancer |
| `just iso` | image ISO de `$HOST-iso` |
| `just install` | disko + `nixos-install` (nouvelle machine) |
| `just ventoy <disk> [size]` | clé USB Ventoy + installeur Nix |

Mise à jour des inputs : `nix flake update` avant un rebuild (`--upgrade` n'a aucun effet sur un flake, ne pas l'utiliser).

Vérifier l'éval sans build : `nix eval .#nixosConfigurations.$HOST.config.system.build.toplevel.drvPath --impure`.

## Secrets (sops-nix)

- `secrets/*.yml`, un fichier par domaine (`tower.yml`, `common.yml`, `anywhere.yml`, `zitadel.yml`, `gitea.yml`, ...), chiffrés avec `sops` + clés `age`.
- 4 clés dans `.sops.yaml` : anywhere, tower, mac, deck. `common.yml` est déchiffrable par toutes les machines ; chaque profil fixe `sops.defaultSopsFile` sur son fichier dédié.
- Créer un secret **neuf** ne nécessite que les clés publiques déjà dans `.sops.yaml` : `nix run nixpkgs#sops -- -e --filename-override secrets/<nom>.yml --output secrets/<nom>.yml <plaintext>`. Éditer un fichier **existant** en place exige la clé privée (root uniquement).

## Services auto-hébergés (tower/laptop)

Registre dans `services/default.nix`. Actifs sur tower :

- **Infra / réseau** : `newt` (tunnel Pangolin), `autossh`, `eternal-terminal`, `adguard`, `tor`, `wayvnc`, `cage-firefox`.
- **Comptes / auth** : `zitadel` (OIDC), `vaultwarden`.
- **Cloud / fichiers** : `nextcloud` (+ postgres), `gitea`.
- **Médias** : `jellyfin`, `navidrome`, `audiobookshelf`, `radarr`/`sonarr`/`readarr`/`prowlarr`/`flaresolverr`, `qbittorrent`/`rqbit`, `media` (dataset partagé `/srv/media`).
- **Passerelles Matrix** : `matrix` (Synapse), `matrix-whatsapp`, `matrix-signal`, `matrix-discord`, `matrix-meta`, `matrix-linkedin`.
- **Agent Hermes** : `hermes` (gateway + plugins), `hermes-webui`, `hermes-dashboard`, `hermes-pocket` (backend app mobile), `discord-bot`.
- **Serveurs MCP** (outils pour Hermes) : `nextcloud-mcp`, `amazon-mcp`, `firefox-mcp`, `zitadel-mcp`, `roku`, `codeberg-mcp`, `ibkr-mcp`, `meetup-mcp`, `gitea-mcp`, `arr-mcp`, `mcp-nixos`. `protonmail-mcp` est tower-only (importé directement depuis `flake.nix`, pas dans le registre).
- **Autres apps** : `jupyterhub`.
- **Désactivés dans le registre** (commentés, à réparer ou en attente) : `dnscrypt`, `minio`, `stalwart-mcp` (cargoHash), `gotify`, `kanidm`, `syncserver`, `matrix-telegram` (attend api_id/api_hash), `vaultwarden-mcp` (input manquant).

## Conventions

- Commentaires et messages de commit en français, format conventional commits (`feat(scope): ...`, `fix(scope): ...`, `chore(scope): ...`), groupés par thème logique (pas un commit par fichier touché).
- Un module est "activé" en étant ajouté à la liste d'imports de son registre (`services/default.nix`, `profiles/common/default.nix`, `users/marc/home.nix`, ...) ; commenté = désactivé mais gardé comme référence.
- `home-manager.users.marc` ne doit **jamais** être câblé dans un `nixosConfigurations` : le profil de marc reste en Home Manager standalone (`just home`), seul `root` passe par le module NixOS (`profiles/common`).
- Repo utilisé en écriture concurrente (plusieurs sessions/agents) : vérifier `git status` et l'absence d'un `nixos-rebuild` déjà en cours avant de lancer un switch.
