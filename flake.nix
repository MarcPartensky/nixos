{
  description = "NixOS configuration of Marc";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    hyprland.url = "github:hyprwm/Hyprland";
    nix-search-tv.url = "github:3timeslazy/nix-search-tv";

    nix-on-droid = {
      url = "github:nix-community/nix-on-droid/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nur = {
      url = "github:nix-community/NUR";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix.url = "github:ryantm/agenix";
    microvm.url = "github:astro/microvm.nix";
    nwg-dock-hyprland-pin-nixpkgs.url = "nixpkgs/2098d845d76f8a21ae4fe12ed7c7df49098d3f15";
  };
  outputs = { self, nixpkgs, nur, ... } @ inputs: {

    nixOnDroidConfigurations.default = inputs.nix-on-droid.lib.nixOnDroidConfiguration {
      pkgs = import nixpkgs { system = "aarch64-linux"; };
      modules = [
        ./profiles/nix-on-droid/configuration.nix
        # ./users.nix
      ];
    };

    nixosConfigurations = {
      laptop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          inputs.home-manager.nixosModules.default
          ./hosts/laptop/hardware-configuration.nix
          ./profiles/laptop/configuration.nix
          ./users.nix
          ./users/marc
        ];
      };

      tower = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/tower/hardware-configuration.nix
          ./profiles/laptop/configuration.nix
          ./users.nix
          ./users/marc
        ];
      };
    };

    # homeConfigurations."marc@laptop" = inputs.home-manager.lib.homeManagerConfiguration {
    #   pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
    #   specialArgs = { inherit inputs; };

    #   modules = [
    #     {
    #       wayland.windowManager.hyprland = {
    #         enable = true;
    #         # set the flake package
    #         package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    #         portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
    #       };
    #     }
    #     # ...
    #   ];
    # };

    # homeConfigurations = {
    #   "marc@laptop" = inputs.home-manager.lib.homeManagerConfiguration {
    #     pkgs = nixpkgs.legacyPackages.x86_64-linux;
    #     specialArgs = { inherit inputs; };
    #     modules = [
    #       {
    #         wayland.windowManager.hyprland = {
    #           enable = true;
    #           # set the flake package
    #           package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    #           portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
    #         };
    #       }
    #     ];
    #   };
    # };
  };
}
