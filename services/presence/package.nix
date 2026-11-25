# Paquet Rust du service de presence (voir default.nix pour le module).
# Isole du module pour pouvoir le construire seul : `nix build .#presence`.
{pkgs, ...}:
pkgs.rustPlatform.buildRustPackage {
  pname = "presence";
  version = "0.1.0";
  src = ./rust;
  # Cargo.lock ne contient que des crates du registre : importCargoLock les
  # epingle par checksum, aucun vendorHash a maintenir.
  cargoLock.lockFile = ./rust/Cargo.lock;
  cargoBuildFlags = ["--locked"];
  # SQLite de nixpkgs (lecture de state.db de Hermes) : on se lie a la
  # bibliotheque du systeme plutot que de compiler l'amalgame C (feature
  # `bundled`), donc pkg-config est la seule outil de build supplementaire.
  # Le client Postgres, lui, est en Rust pur : rien a lier.
  nativeBuildInputs = [pkgs.pkg-config];
  buildInputs = [pkgs.sqlite];
  # Le binaire embarque la page (include_str!) : aucun fichier a cote.
  doCheck = false;
  meta = {
    description = "Presence de marc (appareils, lieu, prevision, reservation CPU)";
    mainProgram = "presence";
  };
}
