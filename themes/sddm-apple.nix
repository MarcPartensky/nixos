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
  pname = "sddm-apple";
  version = "1..0";
  dontBuild = true;
  src = fetchFromGitHub {
    owner = "vfosterm";
    repo = "nixos-sddm-theme-noBlur";
    rev = "master";
    sha256 = "sha256-Hxifk68xVfnL9EWBicHctzJqyowkCBhAZgSLd7ZZXvg=";
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
    cp -aR $src $out/share/sddm/themes/sddm-apple
  '';

}
