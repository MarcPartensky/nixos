# Client YouTube Music TUI "yt-collate" (github:indigo0445/yt-collate).
# Pas de flake upstream : empaqueté ici sur python313.
{lib, pkgs, ...}: let
  pythonPackages = pkgs.python313Packages;

  yt-collate = pythonPackages.buildPythonApplication rec {
    pname = "yt-collate";
    version = "0.0.5";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "indigo0445";
      repo = "yt-collate";
      rev = "a573f2547a331d618b492f814d4bf90f273d1078";
      hash = "sha256-BhINQjegbPvE1leNGRGDnkOaAm7u/H1J2IXQfTJhtuU=";
    };

    build-system = with pythonPackages; [setuptools];

    dependencies = with pythonPackages; [
      textual
      ytmusicapi
      pydantic
      pydantic-settings
      pypresence
    ];

    # mpv lit les streams, yt-dlp les résout, node est le JS runtime exigé
    # par yt-dlp pour le challenge YouTube.
    makeWrapperArgs = [
      "--prefix"
      "PATH"
      ":"
      (lib.makeBinPath [pkgs.mpv pkgs.yt-dlp pkgs.nodejs])
    ];

    doCheck = false;

    meta = with lib; {
      description = "Efficient, well-rounded YouTube Music TUI client";
      homepage = "https://github.com/indigo0445/yt-collate";
      license = licenses.mit;
      mainProgram = "yt-collate";
    };
  };
in {
  home.packages = [yt-collate];
}
