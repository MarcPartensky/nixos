# services/anki-sync-server/default.nix
# Serveur de synchronisation Anki auto-hébergé, implémentation OFFICIELLE en
# Rust : le paquet nixpkgs `anki-sync-server` compile uniquement le binaire
# standalone depuis le repo ankitects/anki (même version que le desktop Anki,
# 25.09.4 dans la nixpkgs épinglée). Zéro Python.
#
# Écoute en loopback (127.0.0.1:27701), exposé uniquement via le blueprint
# Pangolin/newt sur anki.marcpartensky.com. PAS de SSO Pangolin : les clients
# Anki (desktop, AnkiMobile, AnkiDroid) ne savent pas suivre une redirection
# navigateur ; l'authentification repose sur le couple utilisateur/mot de passe
# du serveur Anki lui-même (SYNC_USER), transmis en HTTPS par le reverse proxy.
#
# Mot de passe du compte "marc" dans secrets/anki.yml (sops). Le module nixpkgs
# lit passwordFile via LoadCredential systemd (jamais en clair dans le store).
{
  config,
  lib,
  ...
}: {
  sops.secrets."anki-sync-server/password" = {
    key = "password";
    sopsFile = ../../secrets/anki.yml;
  };

  services.anki-sync-server = {
    enable = true;
    address = "127.0.0.1";
    # port par défaut : 27701
    users = [
      {
        username = "marc";
        passwordFile = config.sops.secrets."anki-sync-server/password".path;
      }
    ];
  };

  # Ressource publique Pangolin (newt, site "tower") : anki.marcpartensky.com
  # -> 127.0.0.1:27701. Cle `proxy-resources` + champ `protocol` = schema
  # réellement compris par le Pangolin du VPS (cf. services/newt). Pas d'auth
  # Pangolin (clients natifs). Pas de healthcheck http : le serveur de sync ne
  # sert aucun GET 2xx (les routes /sync/* et /msync/* sont du POST), donc un
  # check sur "/" le marquerait unhealthy et Pangolin le sortirait du LB.
  services.newt.blueprint.proxy-resources."anki-sync-server" = {
    name = "anki-sync-server";
    protocol = "http";
    full-domain = "anki.marcpartensky.com";
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = config.services.anki-sync-server.port;
        method = "http";
      }
    ];
  };

  # Garde-fou : le port local ne doit jamais être ouvert au firewall/LAN.
  assertions = [
    {
      assertion = !(lib.elem config.services.anki-sync-server.port config.networking.firewall.allowedTCPPorts);
      message = "anki-sync-server : le port local ne doit pas être ouvert au firewall (exposition uniquement via Pangolin/newt).";
    }
  ];
}