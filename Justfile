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
    if [ "$fail" -ne 0 ]; then echo "$n files, at least one KO"; exit 1; fi
    echo "syntax OK ($n files)"

# Build a SINGLE flake output (a package, a dev shell), never the NixOS
# toplevel: `just build presence` compiles one derivation. Use `just nixos`
# only to activate a configuration, which necessarily evaluates it whole.
# The build jobs go to the least loaded builder (nix-builders-pick:
# laptop or deck, never tower). Without a reachable builder we refuse (rc 96) instead
# of compiling on marc's CPU; NIXOS_ALLOW_LOCAL_BUILD=1 forces a bounded
# local fallback of 1 job / 1 core.
build name:
    #!/usr/bin/env bash
    set -euo pipefail
    args=()
    if [ -n "${NIXOS_ALLOW_LOCAL_BUILD:-}" ]; then
      echo "just build: bounded local fallback (1 job, 1 core)" >&2
      args+=(--max-jobs 1 --cores 1)
    elif command -v nix-builders-pick >/dev/null; then
      spec="$(nix-builders-pick || true)"
      if [ -z "$spec" ]; then
        echo "REFUSED: no reachable builder (laptop, deck): tower does not compile (marc policy, 25/11/2026)." >&2
        echo "Retry when a builder answers, or NIXOS_ALLOW_LOCAL_BUILD=1 just build {{name}}" >&2
        exit 96
      fi
      args+=(--builders "$spec")
      # No --max-jobs 0 here: in Nix 2.34 it also disables remote builds
      # ("local builds are disabled (max-jobs = 0)"). The picker's reachability
      # check above (rc 96) is what keeps tower from compiling.
    fi
    exec nix build --no-link --print-out-paths "${args[@]}" .#{{name}}

home:
	home-manager switch --flake .#{{env('HM')}}

nixos:
    # Never --impure: tower's conf evaluates in PURE mode since
    # infra-atlas is a locked input (pure-eval policy).
    # nixos-rebuild-gated (module modules/nixos/nixos-rebuild-gated) refuses
    # --impure AND serializes the rebuilds: it takes flock on
    # /var/lib/hermes/.hermes/state/nixos-rebuild.lock itself.
    # Do NOT put a `flock` back here: it would be the SAME file, so the
    # wrapper would wait for a lock the parent shell already holds and the switch
    # would never start (observed on 14/11/2026, two switches blocked
    # 8 minutes at `flock -w 3600 9`).
    sudo nixos-rebuild-gated switch --flake .#{{env('HOST')}}

# Deploys a container taken out of the host conf (deploy/containers.nix): renders the
# podman quadlet into /etc/containers/systemd and restarts the unit.
# No nixos-rebuild, no eval of the NixOS conf.
deploy name:
    sudo {{justfile_directory()}}/deploy/render.sh {{name}} --system

# Takeover of a container still declared in the host conf: stops the NixOS
# podman-<name> unit, then starts the quadlet with the same container name.
# Run BEFORE removing the oci-containers block from the module.
deploy-takeover name:
    sudo {{justfile_directory()}}/deploy/render.sh {{name}} --takeover

# Runs the single MCP server in the foreground, to test a module without
# touching the systemd daemon. The default manifest is empty: only the
# repo's hot modules are served.
mcp-host-run port="4781" manifest="/dev/null":
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{justfile_directory()}}
    env=$(nix build --no-link --print-out-paths .#mcp-host-env)
    MCP_HOST_MODULES=$PWD/mcp/modules \
    MCP_HOST_MANIFEST={{manifest}} \
    MCP_HOST_PORT={{port}} \
      exec "$env/bin/python" mcp/main.py

# Deploys the MCP modules hot: copies mcp/modules to the daemon folder
# and restarts the unit. No nixos-rebuild, no eval.
mcp-deploy:
    sudo install -d -o hermes -g hermes -m 0755 /var/lib/mcp/modules
    sudo rsync -a --delete {{justfile_directory()}}/mcp/modules/ /var/lib/mcp/modules/
    sudo systemctl restart mcp-host.service
    sleep 1
    systemctl --no-pager --lines=0 status mcp-host.service || true

# microvm.nix dev VM: builds if needed then launches the VM in the terminal
# (serial console, marc autologin). The state (/nix/store overlay, qmp socket)
# lives in ~/.local/state/microvms/<name>/, delete this folder to start over
# from a blank VM. Name = key of nixosConfigurations (vms/<name>.nix), default dev.
vm name="dev":
    #!/usr/bin/env bash
    set -euo pipefail
    state="${XDG_STATE_HOME:-$HOME/.local/state}/microvms/{{name}}"
    mkdir -p "$state"
    cd "$state"
    # path: deliberate: works even if vms/<name>.nix is not yet committed
    exec nix run "path:{{justfile_directory()}}#{{name}}"

# Builds a VM's runner without launching it (prewarms, handy to see
# the build errors without a VM in the middle)
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

