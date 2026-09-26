# Client YouTube Music TUI "youtube-music-cli" (github:involvex/youtube-music-cli).
# Distribution officielle = binaire Bun standalone (aucun Node/Bun requis).
{lib, pkgs, ...}: let
  youtube-music-cli = pkgs.stdenv.mkDerivation rec {
    pname = "youtube-music-cli";
    version = "0.2.3";

    src = pkgs.fetchurl {
      url = "https://github.com/involvex/youtube-music-cli/releases/download/v${version}/youtube-music-cli-linux-x64";
      hash = "sha256-dhsZt0CXnXxgvYksMpF3DL4gdPWzVWDqAYtZq0NTsNE=";
    };

    dontUnpack = true;
    nativeBuildInputs = [pkgs.makeWrapper];

    installPhase = ''
      runHook preInstall
      install -Dm755 $src $out/bin/youtube-music-cli
      wrapProgram $out/bin/youtube-music-cli \
        --prefix PATH : ${lib.makeBinPath [pkgs.mpv pkgs.yt-dlp]}
      ln -s youtube-music-cli $out/bin/ymc
      runHook postInstall
    '';

    meta = with lib; {
      description = "Terminal UI music player for YouTube Music (binaire standalone)";
      homepage = "https://github.com/involvex/youtube-music-cli";
      license = licenses.mit;
      mainProgram = "youtube-music-cli";
      platforms = ["x86_64-linux"];
    };
  };
in {
  home.packages = [youtube-music-cli];
}
