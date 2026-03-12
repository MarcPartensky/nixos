{
  config,
  pkgs,
  lib,
  ...
}: let
  # On force explicitement l'utilisation de Python 3.11 (satisfait la condition 3.10+)
  pythonPackages = pkgs.python311Packages;

  # 1. Définition de la dépendance locale "geoip2fast"
  geoip2fast = pythonPackages.buildPythonPackage rec {
    pname = "geoip2fast";
    version = "1.2.2"; # On utilise la version exacte demandée par tewi
    pyproject = true;

    src = pythonPackages.fetchPypi {
      inherit pname version;
      # ⚠️ Laisse ce hash tel quel pour le premier lancement,
      # Nix va planter et te donner le vrai hash de geoip2fast 1.2.2 à copier ici !
      hash = "sha256-OIFXAM7f6xl9UbS4czsNT3lls23hUUfBJVJxJPi0XWs=";
    };

    build-system = with pythonPackages; [setuptools];
    doCheck = false;
  };

  # 2. Définition de l'application principale "tewi"
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
      platformdirs # <-- Ajout de la dépendance identifiée dans pyproject.toml
      # Appel de la variable définie plus haut
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
  # Le mot clé "in" indique qu'on a fini de déclarer nos variables (let).
  # On peut maintenant utiliser "tewi" pour l'installer dans notre environnement.
  home.packages = [tewi];
}
