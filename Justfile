# set dotenv-load := true
set dotenv-load
# set dotenv-path := .env

# export HOST := env_var("HOST")

home:
	home-manager switch --flake .#marc

nixos:
    sudo nixos-rebuild switch --upgrade --impure --flake .#{{env('HOST')}}

iso:
    nix build .#nixosConfigurations.{{env('HOST')}}-iso.config.system.build.isoImage > nixos.iso

droid:
    nix-on-droid switch --flake ~/.config/nixos#default

install:
    nix-shell -p disko --run "disko -f .#laptop -m disko --argstr device /dev/diskname"
    nixos-install --root /mnt --flake .#laptop

ventoy disk size="32000":
    ventoy -I {{disk}} -r {{size}} -g
    sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --no-daemon
    disko -f .#laptop -m disko --argstr "device={{disk}}" ./hosts/disk/default.nix

