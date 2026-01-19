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
            "@ByteArray(wUQ/AMQATShMtwm8UpQfGQ==:8bUAN8WTM5IEQ3qzDjYkiA4Rj/23RxnVfZLHk0M1REMyfH7vKLY7RwFMmgQf9lyNkr/KOlRvK9MN1s5uKGC7Dg==)";
          # LocalHostAuth = true; # Optionnel: Peut être utile pour l'accès local
        };
      };
    };
  };
}
