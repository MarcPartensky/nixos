{ pkgs, ... }:

let
  pyEnv = pkgs.python3.withPackages (ps: with ps; [
    flask
    apscheduler
    spotipy
    pandas
    openpyxl
    pyopenssl
    python-dotenv
  ]);

  src = pkgs.fetchFromGitHub {
    owner = "storizzi";
    repo = "playsched";
    rev = "main";
    sha256 = "sha256-7mWc+qT+y+lirIZEBnrfXJ/3wLkiy5Vnp6fZS2f2rGU=";
  };

in
{
  home.packages = [
    (pkgs.writeShellScriptBin "playsched-web" ''
      ${pyEnv}/bin/python ${src}/playsched.py "$@"
    '')

    (pkgs.writeShellScriptBin "playsched-cli" ''
      ${pyEnv}/bin/python ${src}/play_spotify_playlist.py "$@"
    '')
  ];
}
