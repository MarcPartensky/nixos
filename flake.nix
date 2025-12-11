{
  description = "NixOS configuration of Marc";
  inputs = {
    # darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-24.05";
    # darwin.inputs.nixpkgs.follows = "nixpkgs";
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    hyprland.url = "github:hyprwm/Hyprland?ref=v0.50.0";
    hy3.url = "github:outfoxxed/hy3?ref=hl0.50.0";
    # hy3.url = "github:outfoxxed/hy3";
    hy3.inputs.hyprland.follows = "hyprland";
    # nix-search-tv.url = "github:3timeslazy/nix-search-tv";
    catppuccin.url = "github:catppuccin/nix";
    newt.url = "github:fosrl/newt";
    claude-code.url = "github:sadjow/claude-code-nix";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    sops.url = "github:Mic92/sops-nix";

    nixvim.url = "github:nix-community/nixvim/nixos-25.11";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    # rycee-nurpkgs = {
    #   url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
    
    hyprtasking = {
      url = "github:raybbian/hyprtasking";
      inputs.hyprland.follows = "hyprland";
    };

    catppuccin-thunderbird = {
      url = "github:catppuccin/thunderbird";
      flake = false; # The repo isn't a flake; use as raw source
    };

    nix-on-droid = {
      url = "github:nix-community/nix-on-droid/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };
    home-manager = {
      # url = "github:nix-community/home-manager/release-25.05";
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nur = {
      url = "github:nix-community/NUR";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # sopswarden = {
    #   url = "github:pfassina/sopswarden";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
    agenix.url = "github:ryantm/agenix";
    microvm.url = "github:astro/microvm.nix";
    nwg-dock-hyprland-pin-nixpkgs.url = "nixpkgs/2098d845d76f8a21ae4fe12ed7c7df49098d3f15";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { self, nixpkgs, ... } @ inputs: {

    nixosConfigurations = {
      laptop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          inputs.disko.nixosModules.disko
          inputs.home-manager.nixosModules.default
	        inputs.hyprland.nixosModules.default
	        inputs.nixvim.nixosModules.default
          inputs.catppuccin.nixosModules.catppuccin
          inputs.sops.nixosModules.sops
          # inputs.sopswarden.nixosModules.default
          # inputs.microvm.nixosModules.microvm
          ./hosts/laptop/disko.nix
          ./hosts/laptop/hardware-configuration.nix
          # ./hosts/laptop/hardware-configuration.nix
          ./profiles/laptop/configuration.nix
          ./users.nix
          ./users/marc
          # {
          #   home-manager = {
          #     useGlobalPkgs = true;
          #     useUserPackages = true;
          #     users.marc = ./users/marc/home.nix;
          #     extraSpecialArgs = { inherit inputs; };  # For Home Manager
          #   };
          # }
        ];
      };

      anywhere = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          inputs.disko.nixosModules.disko
          inputs.home-manager.nixosModules.default
          ./profiles/anywhere/configuration.nix
          ./users.nix
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

    nixOnDroidConfigurations.default = inputs.nix-on-droid.lib.nixOnDroidConfiguration {
      pkgs = import nixpkgs { system = "aarch64-linux"; };
      modules = [
        ./profiles/nix-on-droid/configuration.nix
        # ./users.nix
      ];
    };

    homeConfigurations = {
      "marc@laptop" = inputs.home-manager.lib.homeManagerConfiguration {
        # system = "x86_64-linux";
        # pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        pkgs = import nixpkgs { system = "x86_64-linux"; };
        # specialArgs = { inherit inputs; };
        modules = [
          # inputs.disko.homeModule.disko
          # inputs.home-manager.homeModule.default
          # inputs.hyprland.homeManagerModules.default
	  inputs.catppuccin.homeModules.catppuccin
          inputs.nixvim.homeModules.default
	  inputs.sops.homeManagerModules.sops
          ./users/marc/home.nix 
        ];
      };
    };

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
    darwinConfigurations."macos" = inputs.nix-darwin.lib.darwinSystem {
      modules = [ ./hosts/macos/configuration.nix ];
    };
  };
}
