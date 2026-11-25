# thClaws ships a single self-contained binary built for -unknown-linux-gnu.
# It cannot run on NixOS as-is: the interpreter is not FHS and the Tauri GUI
# pulls 12 GTK/webkit libraries even in CLI mode. autoPatchelfHook rewrites the
# RPATH against nix store libraries, wrapGAppsHook3 exports GI/GTK typelib paths.
#
# SYNCHRONIZED COPY of /home/marc/git/thclaws/package.nix. The two must
# carry the same version and the same sha256: the NixOS eval is PURE (no absolute
# path outside the repo, cf skill nixos-pure-eval), so this directory cannot
# import the project flake's file by path. Bump one, bump the other.
#
# Bumping the version: get the tarball and the .sha256 published next to it,
# then `nix hash file --type sha256 --sri <tarball>` for the sha256 below.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  wrapGAppsHook3,
  makeWrapper,
  gtk3,
  webkitgtk_4_1,
  libsoup_3,
  dbus,
  cairo,
  gdk-pixbuf,
  glib,
  wayland,
  pango,
  harfbuzz,
  atk,
  libxkbcommon,
  alsa-lib,
  openssl,
  sqlite,
  zlib,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "thclaws";
  version = "0.156.0";

  src = fetchurl {
    url = "https://github.com/thClaws/thClaws/releases/download/v${finalAttrs.version}/thclaws-v${finalAttrs.version}-x86_64-unknown-linux-gnu.tar.gz";
    sha256 = "sha256-zDEOB1sK/VCb5AElYO/JYUVoxLPGhj/p5XRWK2EkJO8=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    wrapGAppsHook3
    makeWrapper
  ];

  buildInputs = [
    gtk3
    webkitgtk_4_1
    libsoup_3
    dbus
    cairo
    gdk-pixbuf
    glib
    wayland
    pango
    harfbuzz
    atk
    libxkbcommon
    alsa-lib
    openssl
    sqlite
    zlib
    stdenv.cc.cc.lib
  ];

  # Single self-contained binary shipped at the archive root.
  unpackPhase = ''
    runHook preUnpack
    cp $src thclaws.tar.gz
    tar xzf thclaws.tar.gz
    runHook postUnpack
  '';

  # Keep the real binary out of $out/bin so wrapGAppsHook/makeWrapper produce a
  # single launcher: the app warns and double-counts when two copies sit on PATH.
  installPhase = ''
    runHook preInstall
    install -Dm755 thclaws $out/libexec/thclaws
    makeWrapper $out/libexec/thclaws $out/bin/thclaws \
      "''${gappsWrapperArgs[@]}"
    runHook postInstall
  '';

  dontStrip = true;

  meta = {
    description = "Open-source AI agent harness (GUI, CLI, webapp) in native Rust";
    homepage = "https://thclaws.ai";
    license = with lib.licenses; [ asl20 mit ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "thclaws";
  };
})
