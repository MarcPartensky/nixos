{ pkgs, ... }:
let
  # pythonPackages = pkgs.python311Packages;
  pythonPackages = pkgs.python311Packages.override {
    overrides = self: super: {
      # On désactive les tests spécifiquement pour pytest-benchmark
      pytest-benchmark = super.pytest-benchmark.overridePythonAttrs (old: {
        doCheck = false;
      });
      # Si d'autres paquets bloquent (ex: cryptography), tu peux les ajouter ici :
      # cryptography = super.cryptography.overridePythonAttrs (old: { doCheck = false; });
    };
  };

  nxbt = pythonPackages.buildPythonApplication rec {
    pname = "nxbt";
    version = "0.1.4";
    src = pkgs.python3Packages.fetchPypi rec {
      inherit pname version;
      sha256 = "sha256-PryY4jT442AMwllvUn7w744jlqfnA9AWB5k359XFo54=";
    };
    pyproject = true;
    build-system = [
      pythonPackages.setuptools
      pythonPackages.wheel
    ];
    postPatch = ''
      substituteInPlace nxbt/bluez.py \
        --replace-fail "/lib/systemd/system/bluetooth.service" "${pkgs.bluez}/etc/systemd/system/bluetooth.service"
      
      # --- Completely neutralise toggle_clean_bluez on NixOS ---
      # Replace the whole function definition with a no-op
      # substituteInPlace nxbt/bluez.py \
      #   --replace-fail 'def toggle_clean_bluez(toggle):\n    .*time.sleep(0\.5)' \
      #   'def toggle_clean_bluez(toggle): return'



      # --- Fix secrets.txt path (avoid /nix/store) ---
      substituteInPlace nxbt/web/app.py \
          --replace-fail \
          'os.path.dirname(__file__)' \
          '"/tmp"'

    '';
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.bluez pkgs.dbus ];
    propagatedBuildInputs = with pythonPackages; [
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
    dontCheckRuntimeDeps = true;
    doCheck = false;
  };
in
{
  home.packages = [ nxbt ];
}
