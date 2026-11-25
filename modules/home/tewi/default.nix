{
  config,
  pkgs,
  lib,
  ...
}: let
  # We explicitly force the use of Python 3.11 (satisfies the 3.10+ condition)
  pythonPackages = pkgs.python3Packages;

  # 1. Definition of the local dependency "geoip2fast"
  geoip2fast = pythonPackages.buildPythonPackage rec {
    pname = "geoip2fast";
    version = "1.2.2"; # We use the exact version required by tewi
    pyproject = true;

    src = pythonPackages.fetchPypi {
      inherit pname version;
      # Leave this hash as-is for the first launch,
      # Nix will crash and give you the real geoip2fast 1.2.2 hash to copy here!
      hash = "sha256-OIFXAM7f6xl9UbS4czsNT3lls23hUUfBJVJxJPi0XWs=";
    };

    build-system = with pythonPackages; [setuptools];
    doCheck = false;
  };

  # 2. Definition of the main application "tewi"
  tewi = pythonPackages.buildPythonApplication rec {
    pname = "tewi-torrent";
    version = "2.3.1";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "anlar";
      repo = "tewi";
      rev = "v${version}";
      hash = "sha256-+8yLgwH1toxN99mwlNEFrSeBwko0ZTAHCtDQIkoisy8=";
    };

    build-system = with pythonPackages; [
      setuptools
      wheel
    ];

    propagatedBuildInputs = with pythonPackages; [
      textual
      transmission-rpc
      qbittorrent-api
      pyperclip
      platformdirs # <-- Addition of the dependency identified in pyproject.toml
      # Call of the variable defined above
      geoip2fast
    ];

    doCheck = false;

    meta = with lib; {
      description = "Text-based interface for BitTorrent clients (Transmission, qBittorrent, Deluge)";
      homepage = "https://github.com/anlar/tewi";
      license = licenses.gpl3Plus;
      mainProgram = "tewi";
    };
  };
in {
  # The keyword "in" indicates that we have finished declaring our variables (let).
  # We can now use "tewi" to install it in our environment.
  home.packages = [tewi];
}
