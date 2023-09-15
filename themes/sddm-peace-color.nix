{ lib
, qtbase
, qtsvg
, qtgraphicaleffects
, qtquickcontrols2
, wrapQtAppsHook
, stdenvNoCC
, fetchFromGitHub
}:
stdenvNoCC.mkDerivation
rec {
  pname = "sddm-peace-color";
  version = "1..0";
  dontBuild = true;
  src = fetchFromGitHub {
    owner = "marcpartensky";
    repo = "sddm-peace-color";
    rev = "master";
    sha256 = "sha256-JRCa8JYkQqkBKQ8YYNNjPrUPY3WwiEkq0W3pBmlhbEs=";
  };
  nativeBuildInputs = [
    wrapQtAppsHook
  ];

  propagatedUserEnvPkgs = [
    qtbase
    qtsvg
    qtgraphicaleffects
    qtquickcontrols2
  ];


  installPhase = ''
    mkdir -p $out/share/sddm/themes
    cp -aR $src $out/share/sddm/themes/sddm-peace-color
  '';

}
