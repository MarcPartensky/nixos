# Client YouTube Music TUI "yt-collate" (github:indigo0445/yt-collate).
# No upstream flake: packaged here on python313.
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

    # mpv plays the streams, yt-dlp resolves them, node is the JS runtime required
    # by yt-dlp for the YouTube challenge.
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
