# set dotenv-load := true
set dotenv-load
# set dotenv-path := .env

# export HOST := env_var("HOST")

home-manager:
	home-manager switch --flake .#marc@{{env('HOST')}}

computer:
    sudo nixos-rebuild switch --upgrade --flake .#{{env('HOST')}}

droid:
    nix-on-droid switch --flake ~/.config/nixos#default
