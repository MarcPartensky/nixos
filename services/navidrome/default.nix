{
  config,
  pkgs,
  lib,
  ...
}:

{
  services.navidrome = {
    enable = true;
    settings = {
      Address = "0.0.0.0";
      Port = 4533;
      # Média partagé : /srv/media/music (groupe `media`, cf. services/media),
      # et non plus /home/marc/media/music qui obligeait à donner à navidrome un
      # droit de traversée sur le home de marc (0700) et le faisait scanner une
      # bibliothèque vide.
      MusicFolder = "/srv/media/music";
      # DataFolder = "/var/lib/navidrome/data";
      LogLevel = "info";
      ScanSchedule = "@every 1h";
      TranscodingCacheSize = "500MB";
      DefaultLanguage = "fr";
      # SSO en amont (Pangolin + Zitadel) : le proxy injecte Remote-User quand la
      # session Pangolin est valide (badger). Navidrome n'a pas d'OIDC natif, il
      # sait seulement faire confiance a un en-tete pose par un proxy de confiance.
      # Consequence a connaitre : TrustedSources = 127.0.0.1 fait confiance a TOUT
      # process local ; et la valeur de l'en-tete doit etre EXACTEMENT le user_name
      # Navidrome (sinon un second compte est cree au premier login).
      # /rest/* et /share/* sont hors du gate Pangolin (regles ACCEPT dans
      # Pangolin), donc les clients Subsonic gardent leur Basic auth.
      ExtAuth.TrustedSources = "127.0.0.1/32";
      ExtAuth.UserHeader = "Remote-User";
    };
  };

  systemd.services.navidrome = {
    serviceConfig = {
      StateDirectory = "navidrome";
      DeviceAllow = "";
      LockPersonality = true;
      PrivateDevices = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      # La musique n'est plus dans /home : plus besoin de BindPaths ni de
      # traverser le home, le durcissement du module peut rester actif.
      ProtectHome = lib.mkForce true;
    };
  };

  # Exposition publique via Pangolin (newt, site "tower") : navidrome.marcpartensky.com
  # -> 127.0.0.1:4533. Schéma `proxy-resources` + `protocol` = celui compris par
  # le Pangolin du VPS (cf. services/newt, services/radarr).
  #
  # SSO Pangolin : Zitadel est IdP global de Pangolin, le login de l'UI web passe
  # par Zitadel, et badger injecte Remote-User que Navidrome lit via ExtAuth
  # (cf. settings ci-dessus), donc pas de second login dans l'app.
  # Les clients Subsonic (Feishin, apps mobiles) ne suivent pas un redirect
  # navigateur : /rest/* et /share/* sont sortis du gate par des règles ACCEPT
  # côté Pangolin (ressource 62, applyRules), ils restent en Basic auth.
  services.newt.blueprint.proxy-resources.navidrome = {
    name = "navidrome";
    protocol = "http";
    full-domain = "navidrome.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 4533;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 4533;
          path = "/ping";
          scheme = "http";
          mode = "http";
          method = "GET";
          interval = 30;
          unhealthy-interval = 30;
          timeout = 5;
          healthy-threshold = 1;
          unhealthy-threshold = 3;
        };
      }
    ];
  };

  # Pas d'openFirewall : tower est derrière le NAT, seul le tunnel newt expose
  # Navidrome, et le SSO Pangolin + son auth propre filtrent les accès.
  # networking.firewall.allowedTCPPorts = [ 4533 ];
}
