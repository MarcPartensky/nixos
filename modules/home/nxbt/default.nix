{ pkgs, ... }:

let
  nxbt = pkgs.python3Packages.buildPythonApplication rec {
    pname = "nxbt";
    version = "0.1.4";

    src = pkgs.python3Packages.fetchPypi {
      inherit pname version;
      sha256 = "sha256-PryY4jT442AMwllvUn7w744jlqfnA9AWB5k359XFo54=";
    };

    pyproject = true;
    
    # On définit le système de build
    build-system = [
      pkgs.python3Packages.setuptools
      pkgs.python3Packages.wheel
    ];

    # On nettoie les contraintes de versions périmées de 2021
    postPatch = ''
      sed -i 's/==[0-9.]*//g' setup.py
      # On remplace le chemin codé en dur par un chemin accessible
      substituteInPlace nxbt/bluez.py \
        --replace "/lib/systemd/system/bluetooth.service" "/tmp/bluetooth.service.fake"
      
      # On s'assure que le fichier existe lors du build (ou on le créera avant de lancer)
      touch /tmp/bluetooth.service.fake
    '';

    nativeBuildInputs = [
      pkgs.pkg-config
    ];

    buildInputs = [
      pkgs.bluez
      pkgs.dbus
    ];

    propagatedBuildInputs = with pkgs.python3Packages; [
      dbus-python
      flask
      flask-socketio
      pynput
      psutil
      jinja2
      eventlet
      blessed
      cryptography
    ];

    # Désactive la vérification stricte des versions au runtime
    # C'est ce qui remplace le hook qui manquait
    dontCheckRuntimeDeps = true;

    doCheck = false;
  };
in
{
  home.packages = [ nxbt ];
}
