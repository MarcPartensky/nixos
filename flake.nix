{
  # inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
  ## after reboot, you can track rolling release by using
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }@inputs:
    let
      lib = nixpkgs.lib;
      mkHost = { my-config, zfs-root, pkgs, system, ... }:
        lib.nixosSystem {
          inherit system;
          modules = [
            ./modules
            (import ./configuration.nix {
              inherit my-config zfs-root inputs pkgs lib;
            })
          ];
        };
    in {
      nixosConfigurations = {
        tower = let
          system = "x86_64-linux";
          pkgs = nixpkgs.legacyPackages.${system};
        in mkHost (import ./hosts/tower { inherit system pkgs; });
      };
    };
}
