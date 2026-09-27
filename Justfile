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

