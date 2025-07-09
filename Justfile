laptop:
    nixos-rebuild switch --flake /etc/nixos#laptop

droid:
    nix-on-droid switch --flake ~/.config/nixos#default

tower:
    nixos-rebuild switch --flake /etc/nixos#tower

