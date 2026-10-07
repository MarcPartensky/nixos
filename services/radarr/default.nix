{
  lib,
  ...
}:

# Radarr = le « Sonarr des films ». Il télécharge/renomme et dépose les films
# dans une racine de bibliothèque, ici /srv/media/movies : le MÊME dossier que
# la bibliothèque « Films » de Jellyfin. C'est ça, la connexion utile : Jellyfin
# surveille le dossier en temps réel (surveillance activée par défaut sur un
# stockage local), donc un film importé apparaît tout seul. Le « Connect »
# Emby/Jellyfin de Radarr (URL + clé API Jellyfin) ne sert qu'à déclencher en
# plus un rescan explicite à chaque import.
{
  services.radarr = {
    enable = true;
    user = "marc";
    group = "users";

    # PIEGE 1 : ne PAS reprendre `dataDir = "/home/marc/radarr"` (valeur du
    # module sonarr, qui a été copiée-collée ici et là : Sonarr TOURNAIT avec
    # -data=/home/marc/radarr). Les deux partageraient le même dossier de config.
    # PIEGE 2 : un dataDir sous /home/marc est impossible pour Radarr : son
    # module pose ProtectHome=true et crée le dossier par systemd-tmpfiles, qui
    # REFUSE tout chemin sous /home/marc (cf. services/jellyfin, section
    # « unsafe path transition »). D'où ce dataDir hors /home.
    dataDir = "/var/lib/radarr/.config/Radarr";

    settings = {
      server = {
        urlbase = "localhost";
        port = 8086;
        bindaddress = "*";
      };
    };
  };

  # Média partagé (cf. services/media) : UMask=0002 pour que les fichiers
  # importés soient modifiables par les autres membres du groupe `media`
  # (le module pose 0022 par défaut, d'où le mkForce).
  systemd.services.radarr.serviceConfig.UMask = lib.mkForce "0002";

  # Exposition publique via Pangolin (newt, site "tower") : radarr.marcpartensky.com
  # -> 127.0.0.1:8086. `site` omis : Pangolin affecte le site qui applique le
  # blueprint. Cle `proxy-resources` + champ `protocol` = schema reellement
  # compris par le Pangolin du VPS (cf. commentaire detaille dans services/newt).
  #
  # SSO Pangolin ACTIVE (contrairement a Jellyfin, qui a besoin de ses clients
  # natifs) : le tunnel newt tape en local, donc Radarr voit les requetes
  # distantes comme locales (127.0.0.1) et sa propre auth
  # "DisabledForLocalAddresses" ne filtrerait RIEN. Sans SSO, l'UI complete et
  # l'API v3 (qui suffit a piloter Radarr) seraient ouvertes a Internet.
  services.newt.blueprint.proxy-resources.radarr = {
    name = "radarr";
    protocol = "http";
    full-domain = "radarr.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = 8086;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 8086;
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

  # Plus de ProtectHome=false ici : depuis que le média est dans /srv/media,
  # Radarr ne touche plus du tout au home de marc (données dans
  # /var/lib/radarr, téléchargements et bibliothèque dans /srv), donc le
  # durcissement du module reste en place.

  # Pas d'openFirewall : comme les autres *arr, Radarr reste joignable
  # uniquement depuis la machine (et par le tunnel/SSO si on l'expose un jour).
}