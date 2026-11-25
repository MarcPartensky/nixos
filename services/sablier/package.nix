# Sablier : demarrage a la demande et arret automatique des workloads.
#
# Absent de nixpkgs 26.05 (verifie : ni `sablier` ni `sablierapp`), d'ou ce
# paquet. Binaire Go statique unique, aucune dependance runtime hors D-Bus.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "sablier";
  version = "1.20.0";

  src = fetchFromGitHub {
    owner = "sablierapp";
    repo = "sablier";
    rev = "v${version}";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  vendorHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  # Pas de tests dans le build : les tests d'integration du provider systemd
  # demarrent un systemd dans testcontainers, impossible dans le sandbox Nix.
  doCheck = false;

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  meta = {
    description = "Start workloads on demand and stop them after inactivity";
    homepage = "https://sablierapp.dev";
    license = lib.licenses.agpl3Only;
    mainProgram = "sablier";
    platforms = lib.platforms.linux;
  };
}
