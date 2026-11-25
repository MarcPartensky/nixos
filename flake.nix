{
  description = "NixOS configuration of Marc";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nur = {
      url = "github:nix-community/NUR";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs-darwin";

    clawdbot.url = "github:clawdbot/nix-clawdbot";
    clawdbot.inputs.nixpkgs.follows = "nixpkgs";
    # hyprland.url = "github:hyprwm/Hyprland?ref=v0.50.0";
    # hy3.url = "github:outfoxxed/hy3?ref=hl0.50.0";
    # hy3.url = "github:outfoxxed/hy3";
    # hy3.inputs.hyprland.follows = "hyprland";
    # nix-search-tv.url = "github:3timeslazy/nix-search-tv";
    catppuccin.url = "github:catppuccin/nix";
    # newt.url = "github:fosrl/newt";
    claude-code.url = "github:sadjow/claude-code-nix";

    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";

    niri.url = "github:sodiboo/niri-flake";
    niri.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    sops.url = "github:Mic92/sops-nix";
    sops.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim/nixos-26.05";
    # nixvim.inputs.nixpkgs.follows = "nixpkgs";

    zen-browser.url = "github:youwen5/zen-browser-flake";
    zen-browser.inputs.nixpkgs.follows = "nixpkgs";

    spicetify.url = "github:Gerg-L/spicetify-nix";
    spicetify.inputs.nixpkgs.follows = "nixpkgs";

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

    # Hermes skins pack (26 palettes): raw source, cf. modules/home-mac/hermes-skins.
    hermes-menagerie = {
      url = "github:ZakiChair/hermes-catppuccin";
      flake = false; # The repo isn't a flake; use as raw source
    };

    # A SPECIAL entry is created for the phone
    # nixpkgs-droid.url = "github:NixOS/nixpkgs/nixos-24.05";

    nix-on-droid = {
      url = "github:nix-community/nix-on-droid/master";
      # url = "github:nix-community/nix-on-droid/release-24.05";

      # THIS IS THE CRUCIAL LINE:
      # It is told to follow the Droid version, not the Laptop version.
      # inputs.nixpkgs.follows = "nixpkgs-droid";

      # The internal home-manager of nix-on-droid is aligned too
      # inputs.home-manager.follows = "home-manager-droid";
    };

    # A home-manager compatible with 24.05 is also defined for the phone
    # home-manager-droid = {
    #   url = "github:nix-community/home-manager/release-24.05";
    #   inputs.nixpkgs.follows = "nixpkgs-droid";
    # };

    # nixvim-droid.url = "github:nix-community/nixvim/nixos-24.05";
    # nixvim-droid.inputs.nixpkgs.follows = "nixpkgs-droid";

    # hyprland-plugins = {
    #   url = "github:hyprwm/hyprland-plugins";
    #   inputs.hyprland.follows = "hyprland";
    # };
    sopswarden = {
      url = "github:pfassina/sopswarden";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix.url = "github:ryantm/agenix";
    microvm.url = "github:astro/microvm.nix";

    # nwg-dock-hyprland-pin-nixpkgs.url = "nixpkgs/2098d845d76f8a21ae4fe12ed7c7df49098d3f15";

    # nixgl.url = "github:guibou/nixGL";
    # nixgl.inputs.nixpkgs.follows = "nixpkgs";

    backtest.url = "github:marcpartensky/backtest-cpp-py";
    backtest.inputs.nixpkgs.follows = "nixpkgs";
    portfolio-optimizer.url = "github:marcpartensky/portfolio-optimizer";
    portfolio-optimizer.inputs.nixpkgs.follows = "nixpkgs";
    option-pricer.url = "github:marcpartensky/option-pricer";
    option-pricer.inputs.nixpkgs.follows = "nixpkgs";

    # Anki MCP addon (ankimcp.ai): no follows, its python deps (mcp >= 1.27)
    # must come from the same nixpkgs as the Anki that loads it
    anki-mcp.url = "github:ankimcp/anki-mcp-server-addon";

    uv2nix.url = "github:pyproject-nix/uv2nix";
    uv2nix.inputs.nixpkgs.follows = "nixpkgs";
    pyproject-nix.url = "github:pyproject-nix/pyproject.nix";
    pyproject-nix.inputs.nixpkgs.follows = "nixpkgs";

    discord-bot.url = "github:MarcPartensky/discord-bot";

    hermes-agent.url = "github:NousResearch/hermes-agent";
    # hermes-agent.inputs.nixpkgs.follows = "github:NousResearch/hermes-agent";

    # Web chat UI (CLI parity) for hermes-agent. Community project
    # (MIT), it publishes its own flake + NixOS module. follows nixpkgs to
    # avoid evaluating a second nixpkgs: the package only does python3 +
    # pyyaml + cryptography, 26.05 is enough.
    hermes-webui = {
      url = "github:nesquena/hermes-webui";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # typer: typing + race rooms (Rust server typer-server, terminal client
    # typer-race). Standalone flake consumed from its public Codeberg repo, so
    # the system repo no longer vendors a copy and one URL resolves on tower
    # AND on macOS. follows nixpkgs to avoid evaluating a second nixpkgs; the
    # package is built with the host's pkgs (see users/mac/home.nix, and the
    # nixos module of the typer flake).
    # Bump the deployed build with: nix flake lock --update-input typer
    typer = {
      url = "git+https://codeberg.org/mazex/typer";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # mnemo: retention engine (scan of Hermes conversations, score,
    # explanation cards, sources for the podcast and the typing). Standalone flake
    # vendored under projects/mnemo; the k3s pod and its image come from its
    # module. follows nixpkgs: the image is built on the laptop with the
    # host's pkgs, and no second nixpkgs is evaluated.
    mnemo = {
      url = "path:./projects/mnemo";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # YouTube Music TUI clients (see modules/home/{ytm-player,yututui,yt-collate,youtube-music-cli})
    ytm-player = {
      url = "github:peternaame-boop/ytm-player";
      # v2.1.0 requires dbus-fast >= 5.0.0, absent from 26.05 (4.0.4):
      # unstable is followed, the nixpkgs the upstream flake tests against.
      inputs.nixpkgs.follows = "unstable";
    };
    yututui = {
      url = "github:Ochichan/Yututui";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stalwart-mcp = {
      # Rust MCP server for Stalwart Mail Server (webpatser/stalwart-mcp).
      # JMAP access: read, search, real-time notifications via EventSource.
      # Pinned on main commit (no tagged release).
      url = "github:webpatser/stalwart-mcp/be2c16d5921f45395996a130a5a643c542ef2105";
      flake = false;
    };

    ankimcp = {
      url = "github:ankimcp/anki-mcp-server-addon";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    jovian.url = "github:Jovian-Experiments/Jovian-NixOS";
    # jovian.inputs.nixpkgs.follows = "nixpkgs";

    steam-config-nix = {
      url = "github:different-name/steam-config-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # 3D atlas of the infra (atlas.marcpartensky.com): separate project under
    # /var/lib/hermes/workspace/infra-atlas. Input `path:` LOCKED in
    # flake.lock instead of a `builtins.getFlake` in the tower profile: it was
    # that getFlake that made the WHOLE tower evaluation impure (pure-eval
    # policy, cf. skill nixos-pure-eval). The atlas flake has no input,
    # so nothing to follow. Consequences to know: a modification of the
    # atlas project only enters the conf after `nix flake update infra-atlas`
    # (the module evaluated remains the one from the lock, not the working tree).
    infra-atlas.url = "path:/var/lib/hermes/workspace/infra-atlas";
  };
  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: {
    nixosConfigurations = {
      laptop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs self;};
        modules = [
          ./profiles/common
          ./profiles/laptop/configuration.nix
          # ./services is tower's monolith: sops secrets of which the laptop
          # is not a recipient, so build is impossible (cf. comment in
          # services/laptop.nix). The laptop imports only what it uses.
          ./services/laptop.nix
        ];
      };

      tower = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs self;};
        modules = [
          ./profiles/common
          ./profiles/tower/configuration.nix
          ./services
        ];
      };

      deck = inputs.jovian.inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs self;};
        modules = [
          ./profiles/deck/configuration.nix
          # ./services
        ];
      };

      laptop-iso = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs self;};
        modules = [
          ./modules/nixos/iso

          inputs.disko.nixosModules.disko
          inputs.nixvim.nixosModules.default
          inputs.sopswarden.nixosModules.default
          inputs.home-manager.nixosModules.default
          ./hosts/laptop/disko.nix
          ./hosts/laptop/hardware-configuration.nix
          ./profiles/laptop/configuration.nix
          ./services
          ./users.nix
        ];
      };

      deck-iso = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [./modules/nixos/iso ./users.nix {programs.zsh.enable = true;}];
      };

      anywhere = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs self;};
        modules = [
          ./profiles/anywhere/configuration.nix
          ./users.nix
        ];
      };

      # microvm.nix dev VM (input `microvm`, see vms/): `just vm` or
      # `nix run .#dev`. Duplicate vms/dev.nix for a 2nd VM.
      dev = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs self;};
        modules = [
          inputs.microvm.nixosModules.microvm
          ./vms/dev.nix
        ];
      };
    };

    # Dev VM runners, launchable directly: `nix run .#dev`.
    # Plus the in-house MCP servers (mcp/default.nix), buildable without
    # evaluating the NixOS conf: `nix build .#shlink-mcp`.
    packages.x86_64-linux =
      import ./mcp {pkgs = nixpkgs.legacyPackages.x86_64-linux;}
      // {
        dev = self.nixosConfigurations.dev.config.microvm.declaredRunner;
      }
      // {
        # Python environment of the single MCP server, for `just mcp-host-run`.
        # Exposed as a package: it replaces the `nix build --impure --expr` that
        # did a getFlake of the current flake.
        mcp-host-env = nixpkgs.legacyPackages.x86_64-linux.python3.withPackages (ps: [ps.fastmcp]);
        # Presence service (Rust): `nix build .#presence` without evaluating the NixOS conf.
        presence = nixpkgs.legacyPackages.x86_64-linux.callPackage ./services/presence/package.nix {};
      };

    # Containers TAKEN OUT of the host conf (deploy/containers.nix), read by
    # `just deploy`. Never imported by nixosConfigurations: modifying them
    # triggers no eval of the NixOS conf.
    deploy.containers = import ./deploy/containers.nix;

    # Nix-on-Droid devices. `default` = the phone (Xiaomi 13T Pro). Each
    # device must have ITS OWN ports on the VPS loopback, otherwise the
    # reverse tunnels fight over the same numbers (see nod-access in
    # profiles/nix-on-droid/hermes-access.nix).
    nixOnDroidConfigurations = let
      mkNod = extraModules:
        inputs.nix-on-droid.lib.nixOnDroidConfiguration {
          # pkgs = import inputs.nixpkgs-droid {
          pkgs = import inputs.nix-on-droid.inputs.nixpkgs {
            system = "aarch64-linux";
          };
          extraSpecialArgs = {inherit inputs;};
          # extraSpecialArgs = {
          #   inputs = inputs // {
          #     nixpkgs = inputs.nixpkgs-droid;
          #     home-manager = inputs.home-manager-droid;
          #     nixvim = inputs.nixvim-droid;
          #   };
          # };
          modules =
            [
              # inputs.home-manager.nixosModules.default
              ./profiles/nix-on-droid/configuration.nix
              # ./users.nix
            ]
            ++ extraModules;
        };
    in {
      default = mkNod [];
      # Tablet: relay 2226, sshd published by wstunnel 2227, proxies 1083/1084.
      tablet = mkNod [
        {
          nod-access = {
            relayPort = 2226;
            wsSshdPort = 2227;
            wsSocksPort = 1083;
            wsHttpPort = 1084;
          };
        }
      ];
    };

    homeConfigurations = {
      "marc" = inputs.home-manager.lib.homeManagerConfiguration {
        extraSpecialArgs = {inherit inputs;};
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          overlays = [inputs.nur.overlays.default inputs.clawdbot.overlays.default];
        };
        modules = [./users/marc/home.nix];
      };
      "marc@macos" = inputs.home-manager.lib.homeManagerConfiguration {
        extraSpecialArgs = {inherit inputs;};
        pkgs = import inputs.nixpkgs-darwin {
          system = "aarch64-darwin";
        };
        modules = [./users/mac/home.nix];
      };
      "marc@deck" = inputs.home-manager.lib.homeManagerConfiguration {
        extraSpecialArgs = {inherit inputs;};
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfree = true;
        };
        modules = [./users/deck];
      };
    };

    darwinConfigurations."macos" = inputs.nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      specialArgs = {inherit inputs self;};
      pkgs = import inputs.nixpkgs-darwin {system = "aarch64-darwin";};
      modules = [
        ./profiles/macos/configuration.nix
        {nixpkgs.config.allowUnfree = true;}
      ];
    };
  };
}
