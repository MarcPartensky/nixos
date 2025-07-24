# set dotenv-load := true
set dotenv-load
# set dotenv-path := .env

# export HOST := env_var("HOST")

computer:
    nixos-rebuild switch --flake /etc/nixos#{{env('HOST')}}

droid:
    nix-on-droid switch --flake ~/.config/nixos#default
