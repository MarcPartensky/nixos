{
  description = "NixOS configuration of Marc";
  inputs = {
    # darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-24.05";
    # darwin.inputs.nixpkgs.follows = "nixpkgs";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    clawdbot.url = "github:clawdbot/nix-clawdbot";
    clawdbot.inputs.nixpkgs.follows = "nixpkgs";
    # hyprland.url = "github:hyprwm/Hyprland?ref=v0.50.0";
    # hy3.url = "github:outfoxxed/hy3?ref=hl0.50.0";
    # hy3.url = "github:outfoxxed/hy3";
    # hy3.inputs.hyprland.follows = "hyprland";
    # nix-search-tv.url = "github:3timeslazy/nix-search-tv";
    catppuccin.url = "github:catppuccin/nix";
    newt.url = "github:fosrl/newt";
    claude-code.url = "github:sadjow/claude-code-nix";

    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";

    niri.url = "github:sodiboo/niri-flake";
    niri.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    sops.url = "github:Mic92/sops-nix";
    sops.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim/nixos-25.11";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    zen-browser.url = "github:youwen5/zen-browser-flake";
    zen-browser.inputs.nixpkgs.follows = "nixpkgs";

    # rycee-nurpkgs = {
    #   url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
    # hyprtasking = {
    #   url = "github:raybbian/hyprtasking";
    #   inputs.hyprland.follows = "hyprland";
    # };
    catppuccin-thunderbird = {
      url = "github:catppuccin/thunderbird";
      flake = false; # The repo isn't a flake; use as raw source
    };

    # On crée une entrée SPÉCIALE pour le téléphone
    # nixpkgs-droid.url = "github:NixOS/nixpkgs/nixos-24.05";

    nix-on-droid = {
      url = "github:nix-community/nix-on-droid/master";
      # url = "github:nix-community/nix-on-droid/release-24.05";
      
      # C'EST LA LIGNE CRUCIALE :
      # On lui dit de suivre la version Droid, pas la version Laptop.
      # inputs.nixpkgs.follows = "nixpkgs-droid"; 
      
      # On aligne aussi le home-manager interne de nix-on-droid
      # inputs.home-manager.follows = "home-manager-droid"; 
    };
    
    # On définit aussi un home-manager compatible 24.05 pour le tel
    home-manager-droid = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs-droid";
    };

    nixvim-droid.url = "github:nix-community/nixvim/nixos-24.05";
    nixvim-droid.inputs.nixpkgs.follows = "nixpkgs-droid";


    # hyprland-plugins = {
    #   url = "github:hyprwm/hyprland-plugins";
    #   inputs.hyprland.follows = "hyprland";
    # };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nur = {
      url = "github:nix-community/NUR";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sopswarden = {
      url = "github:pfassina/sopswarden";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix.url = "github:ryantm/agenix";
    microvm.url = "github:astro/microvm.nix";

    # nwg-dock-hyprland-pin-nixpkgs.url = "nixpkgs/2098d845d76f8a21ae4fe12ed7c7df49098d3f15";

    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    # nixgl.url = "github:guibou/nixGL";
    # nixgl.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { self, nixpkgs, ... } @ inputs: {

    nixosConfigurations = {
      laptop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          inputs.disko.nixosModules.disko
	      inputs.nixvim.nixosModules.default
          inputs.catppuccin.nixosModules.catppuccin
          # inputs.sops.nixosModules.sops  # Inclus dans sopswarden
          inputs.sopswarden.nixosModules.default
          # inputs.microvm.nixosModules.microvm
          inputs.home-manager.nixosModules.default
          ./hosts/laptop/disko.nix
          ./hosts/laptop/hardware-configuration.nix
          ./profiles/laptop/configuration.nix
          ./services
          ./users.nix
        ];
      };

      anywhere = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          inputs.disko.nixosModules.disko
          inputs.home-manager.nixosModules.default
          # inputs.sopswarden.homeManagerModules.default
          ./profiles/anywhere/configuration.nix
          ./users.nix
          # ./services
          ./services/traefik
          ./services/postgres
          ./services/vaultwarden
          ./services/nextcloud
          ./services/pangolin
          # ./services/stalwart
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
      # pkgs = import inputs.nixpkgs-droid {
      pkgs = import inputs.nixpkgs {
        system = "aarch64-linux";
      };
      extraSpecialArgs = { inherit inputs; };
      # extraSpecialArgs = { 
      #   inputs = inputs // {
      #     nixpkgs = inputs.nixpkgs-droid;
      #     home-manager = inputs.home-manager-droid;
      #     nixvim = inputs.nixvim-droid;
      #   };
      # };
      modules = [
        # inputs.home-manager.nixosModules.default
        ./profiles/nix-on-droid/configuration.nix
        # ./users.nix
      ];
    };

    homeConfigurations = {
      "marc@laptop" = inputs.home-manager.lib.homeManagerConfiguration {
        # system = "x86_64-linux";
        # pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = { inherit inputs; };
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          overlays = [ inputs.nur.overlays.default inputs.clawdbot.overlays.default ];
        };
        modules = [
          # inputs.disko.homeModule.disko
      	  inputs.catppuccin.homeModules.catppuccin
          inputs.nixvim.homeModules.default
          inputs.sops.homeManagerModules.sops
          inputs.sopswarden.homeManagerModules.default
          inputs.niri.homeModules.niri
          inputs.nix-flatpak.homeManagerModules.nix-flatpak
          inputs.clawdbot.homeManagerModules.clawdbot
          ./users/marc/home.nix 
        ];
      };
    };

    darwinConfigurations."macos" = inputs.nix-darwin.lib.darwinSystem {
      modules = [
        ./hosts/macos/configuration.nix
      ];
    };
  };
}
