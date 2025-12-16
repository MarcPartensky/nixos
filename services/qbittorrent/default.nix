{ pkgs, ... }:
{
    # configuration.nix
  services.qbittorrent = {
    enable = true;
    webuiPort = 8084;
    torrentingPort = 8085;
    serverConfig = {
      LegalNotice.Accepted = true; # Souvent nécessaire pour le démarrage
      Preferences = {
        WebUI = {
          Username = "marc"; # Remplacez par le nom d'utilisateur souhaité
          Password_PBKDF2 =
          "@ByteArray(SsGjkRSKiMK3xulanOsYwA==:EgV/gBmgvnEm9uuudKAmYRWLFuPhq4qUn21vx6Hf5kKayPiXrIYrPxeO7dx2h7Aj/Id7cnvilhMt05GzaB/dfQ==)"; # Remplacez par le hash de votre mot de passe
          # LocalHostAuth = true; # Optionnel: Peut être utile pour l'accès local
        };
      };
    };
  };
}
