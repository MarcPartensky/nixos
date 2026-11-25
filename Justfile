# set dotenv-load := true
set dotenv-load
# set dotenv-path := .env

# export HOST := env_var("HOST")

run:
    just {{env('RUN')}}

# Syntax check of every tracked .nix file. Milliseconds, no eval, no build:
# catches a missing comma or paren without instantiating nixpkgs.
check:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{justfile_directory()}}
    fail=0
    n=0
    while IFS= read -r f; do
      n=$((n + 1))
      nix-instantiate --parse "$f" > /dev/null || { echo "KO  $f"; fail=1; }
    done < <(git ls-files '*.nix')
    if [ "$fail" -ne 0 ]; then echo "$n fichiers, au moins un KO"; exit 1; fi
    echo "syntaxe OK ($n fichiers)"

# Build a SINGLE flake output (a package, a dev shell), never the NixOS
# toplevel: `just build presence` compiles one derivation. Use `just nixos`
# only to activate a configuration, which necessarily evaluates it whole.
# Les jobs de build partent sur le builder le moins charge (nix-builders-pick :
# laptop ou deck, jamais tower). Sans builder joignable on refuse (rc 96) au lieu
# de compiler sur le CPU de marc ; NIXOS_ALLOW_LOCAL_BUILD=1 force un repli
# local borne a 1 job / 1 coeur.
build name:
    #!/usr/bin/env bash
    set -euo pipefail
    args=()
    if [ -n "${NIXOS_ALLOW_LOCAL_BUILD:-}" ]; then
      echo "just build: repli local borne (1 job, 1 coeur)" >&2
      args+=(--max-jobs 1 --cores 1)
    elif command -v nix-builders-pick >/dev/null; then
      spec="$(nix-builders-pick || true)"
      if [ -z "$spec" ]; then
        echo "REFUS: aucun builder (laptop, deck) joignable : tower ne compile pas (politique marc, 25/11/2026)." >&2
        echo "Reessaie quand un builder repond, ou NIXOS_ALLOW_LOCAL_BUILD=1 just build {{name}}" >&2
        exit 96
      fi
      args+=(--builders "$spec")
    fi
    exec nix build --no-link --print-out-paths "${args[@]}" .#{{name}}

home:
	home-manager switch --flake .#{{env('HM')}}

nixos:
    # Jamais --impure : la conf de tower s'evalue en PUR depuis que
    # l'infra-atlas est un input verrouille (politique pure-eval).
    # nixos-rebuild-gated (module modules/nixos/nixos-rebuild-gated) refuse
    # --impure ET serialise les rebuilds : il prend flock sur
    # /var/lib/hermes/.hermes/state/nixos-rebuild.lock lui-meme.
    # NE PAS remettre un `flock` ici : ce serait le MEME fichier, donc le
    # wrapper attendrait un verrou que le shell parent tient deja et le switch
    # ne demarrerait jamais (constate le 14/11/2026, deux switches bloques
    # 8 minutes a `flock -w 3600 9`).
    sudo nixos-rebuild-gated switch --flake .#{{env('HOST')}}

# Deploie un conteneur sorti de la conf hote (deploy/containers.nix) : rend le
# quadlet podman dans /etc/containers/systemd et redemarre l'unite.
# Aucun nixos-rebuild, aucun eval de la conf NixOS.
deploy name:
    sudo {{justfile_directory()}}/deploy/render.sh {{name}} --system

# Reprise d'un conteneur encore declare dans la conf hote : arrete l'unite
# podman-<nom> de NixOS, puis demarre le quadlet avec le meme nom de conteneur.
# A lancer AVANT de retirer le bloc oci-containers du module.
deploy-takeover name:
    sudo {{justfile_directory()}}/deploy/render.sh {{name}} --takeover

# Lance le serveur MCP unique en avant-plan, pour tester un module sans
# toucher au demon systemd. Le manifeste par defaut est vide : seuls les
# modules a chaud du depot sont servis.
mcp-host-run port="4781" manifest="/dev/null":
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{justfile_directory()}}
    env=$(nix build --no-link --print-out-paths .#mcp-host-env)
    MCP_HOST_MODULES=$PWD/mcp/modules \
    MCP_HOST_MANIFEST={{manifest}} \
    MCP_HOST_PORT={{port}} \
      exec "$env/bin/python" mcp/main.py

# Deploie les modules MCP a chaud : copie mcp/modules vers le dossier du demon
# et redemarre l'unite. Aucun nixos-rebuild, aucun eval.
mcp-deploy:
    sudo install -d -o hermes -g hermes -m 0755 /var/lib/mcp/modules
    sudo rsync -a --delete {{justfile_directory()}}/mcp/modules/ /var/lib/mcp/modules/
    sudo systemctl restart mcp-host.service
    sleep 1
    systemctl --no-pager --lines=0 status mcp-host.service || true

# VM de dev microvm.nix : construit si besoin puis lance la VM dans le terminal
# (console série, autologin marc). L'état (overlay du /nix/store, socket qmp)
# vit dans ~/.local/state/microvms/<nom>/, supprimer ce dossier pour repartir
# d'une VM vierge. Nom = clé de nixosConfigurations (vms/<nom>.nix), défaut dev.
vm name="dev":
    #!/usr/bin/env bash
    set -euo pipefail
    state="${XDG_STATE_HOME:-$HOME/.local/state}/microvms/{{name}}"
    mkdir -p "$state"
    cd "$state"
    # path: volontaire : marche même si vms/<nom>.nix n'est pas encore commité
    exec nix run "path:{{justfile_directory()}}#{{name}}"

# Construit le runner d'une VM sans la lancer (préchauffe, pratique pour voir
# les erreurs de build sans VM au milieu)
vm-build name="dev":
    nix build --no-link "path:{{justfile_directory()}}#{{name}}"

iso:
    nix build .#nixosConfigurations.{{env('HOST')}}-iso.config.system.build.isoImage > nixos.iso

mac:
    # darwin-rebuild switch --flake .#macos
    sudo nix --extra-experimental-features 'flakes nix-command' run nix-darwin -- switch --flake .#macos

droid:
    nix-on-droid switch --flake ~/.config/nixos#default

install:
    nix-shell -p disko --run "disko -f .#laptop -m disko --argstr device /dev/diskname"
    nixos-install --root /mnt --flake .#laptop

ventoy disk size="32000":
    ventoy -I {{disk}} -r {{size}} -g
    sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --no-daemon
    disko -f .#laptop -m disko --argstr "device={{disk}}" ./hosts/disk/default.nix

