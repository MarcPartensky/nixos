{
  description = "NixOS configuration of Marc";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    hyprland.url = "github:hyprwm/Hyprland";
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
  };
  outputs = { self, nixpkgs, ... } @ inputs: {
    nixosConfigurations = {
      laptop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./configuration.nix
          ./hosts/laptop/hardware-configuration.nix
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
