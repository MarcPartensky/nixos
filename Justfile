# set dotenv-load := true
set dotenv-load
# set dotenv-path := .env

# export HOST := env_var("HOST")

home:
	home-manager switch --flake .#marc@{{env('HOST')}}

nixos:
    sudo nixos-rebuild switch --upgrade --impure --flake .#{{env('HOST')}}

iso:
		nix build .#nixosConfigurations.{{env('HOST')}}.config.system.build.isoImage > nixos.iso

droid:
    nix-on-droid switch --flake ~/.config/nixos#default
