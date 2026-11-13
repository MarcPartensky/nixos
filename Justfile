# set dotenv-load := true
set dotenv-load
# set dotenv-path := .env

# export HOST := env_var("HOST")

run:
    just {{env('RUN')}}

home:
	home-manager switch --flake .#{{env('HM')}}

nixos:
    sudo nixos-rebuild switch --impure --flake .#{{env('HOST')}}

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
    env=$(nix build --impure --no-link --print-out-paths --expr '
      with import (builtins.getFlake "path:{{justfile_directory()}}").inputs.nixpkgs { system = "x86_64-linux"; };
      python3.withPackages (ps: [ ps.fastmcp ])')
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

