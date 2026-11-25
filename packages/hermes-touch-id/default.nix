{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  sdk = pkgs.apple-sdk;
  frameworks = "${sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks";
in
  pkgs.stdenv.mkDerivation {
    pname = "hermes-touch-id";
    version = "1.0.0";
    src = ./.;

    # LocalAuthentication is not in nixpkgs' "legacy" frameworks:
    # we compile against the full SDK (pkgs.apple-sdk) provided by nixpkgs-darwin.
    buildPhase = ''
      runHook preBuild
      $CC -fobjc-arc -O2 ''${NIX_CFLAGS_COMPILE:-} \
        -F${frameworks} \
        -framework Foundation -framework LocalAuthentication \
        hermes-touch-id.m -o hermes-touch-id
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -D -m 0755 hermes-touch-id $out/bin/hermes-touch-id
      runHook postInstall
    '';

    doCheck = false;
    meta = {
      description = "Native biometric validation (Touch ID) for Hermes root approvals";
      platforms = lib.platforms.darwin;
      mainProgram = "hermes-touch-id";
    };
  }
