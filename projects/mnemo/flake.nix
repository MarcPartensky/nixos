# mnemo: score Marc's conversations, explain the gaps, feed the podcast
# pipeline and the typing drill.
#
# The flake is standalone (`nix build .#`, `nix run .#`, `nix develop`) and also
# exports `nixosModules.default`, so the system flake deploys it. The image is
# built HERE, on the laptop, never on tower: a Rust build belongs where the CPU
# is free, and the pod on tower only pulls the tarball.
#
#   nix build .#image        # -> result/mnemo-oci.tar
#   nixos-rebuild --flake .# on the laptop, or scp the tar to tower
{
  description = "mnemo: retention engine for Marc's conversations (Rust, k3s pod, Pangolin + OIDC)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = f:
      nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    packages = forAllSystems (pkgs: let
      mnemo = pkgs.callPackage ./package.nix {};
    in {
      inherit mnemo;
      image = pkgs.callPackage ./image.nix {inherit mnemo;};
      default = mnemo;
    });

    nixosModules.default = import ./module.nix;
    nixosModules.mnemo = self.nixosModules.default;

    checks = forAllSystems (pkgs: let
      # Evaluating the module against a throwaway system catches a wrong option
      # name here, on the laptop, instead of during a tower rebuild. The output
      # is the pod manifest the cluster would receive.
      pod = pkgs.nixos [
        self.nixosModules.default
        {
          system.stateVersion = "26.05";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "/dev/null";
            fsType = "ext4";
          };
          services.postgresql.enable = true;
          services.k3s.enable = true;
          services.k3s.role = "server";
          services.mnemo.enable = true;
        }
      ];
    in {
      inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) mnemo;
      mnemo-pod-manifest = pkgs.writeText "mnemo-pod.yaml" (pkgs.lib.generators.toYAML {} pod.config.services.k3s.manifests.mnemo.content);
    });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = with pkgs; [
          cargo
          rustc
          rust-analyzer
          clippy
          rustfmt
          sqlite # inspect a copy of the Hermes state database
          postgresql # psql against the mnemo database
          jq
          curl
        ];
        RUST_BACKTRACE = "1";
      };
    });

    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
