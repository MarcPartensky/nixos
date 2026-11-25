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

    # LocalAuthentication n'est pas dans les frameworks « legacy » de nixpkgs :
    # on compile contre le SDK complet (pkgs.apple-sdk) fourni par nixpkgs-darwin.
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
      description = "Validation biometrique native (Touch ID) pour les approbations root d'Hermes";
      platforms = lib.platforms.darwin;
      mainProgram = "hermes-touch-id";
    };
  }
