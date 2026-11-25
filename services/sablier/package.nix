# Sablier: on-demand startup and automatic shutdown of workloads.
#
# Absent from nixpkgs 26.05 (verified: neither `sablier` nor `sablierapp`), hence this
# package. Single static Go binary, no runtime dependency other than D-Bus.
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

  # No tests in the build: the systemd provider integration tests
  # start a systemd inside testcontainers, impossible in the Nix sandbox.
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
