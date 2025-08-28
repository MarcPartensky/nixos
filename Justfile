# set dotenv-load := true
set dotenv-load
# set dotenv-path := .env

# export HOST := env_var("HOST")

computer:
    sudo nixos-rebuild switch --flake .#{{env('HOST')}}

droid:
    nix-on-droid switch --flake ~/.config/nixos#default
