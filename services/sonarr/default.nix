{
  lib,
  pkgs,
  ...
}:

# Sonarr = séries TV. Le module nixpkgs pose deux valeurs incompatibles avec un
# dataDir sous /home : ProtectHome=true (le service ne verrait pas /home) et la
# création du dossier par systemd-tmpfiles, qui refuse tout chemin sous
# /home/marc (« unsafe path transition », cf. services/jellyfin).
# Historiquement ce module pointait sur /home/marc/radarr (copier-coller depuis
# le module radarr), donc Sonarr tournait sans pouvoir lire ni écrire sa
# configuration : le dossier était figé au 28/07/2026 et son port 8006 ne
# répondait plus. Réparé le 27/09/2026 : dossier dédié + migration des données.
{
  services.sonarr = {
    enable = true;
    user = "marc";
    group = "users";
    dataDir = "/home/marc/sonarr";
    settings = {
      server = {
        urlbase = "localhost";
        port = 8006;
        bindaddress = "*";
      };
    };
  };

  systemd.services.sonarr.serviceConfig.ProtectHome = lib.mkForce false;

  # Média partagé (cf. services/media) : rend les fichiers importés modifiables
  # par les autres membres du groupe `media`.
  systemd.services.sonarr.serviceConfig.UMask = lib.mkForce "0002";

  # La règle tmpfiles du module viserait /home/marc/sonarr, que
  # systemd-tmpfiles refuserait de créer et signalerait à chaque activation :
  # supprimée, le dossier est créé par la migration ci-dessous.
  systemd.tmpfiles.settings."10-sonarr" = lib.mkForce { };

  # Migration en une fois : Sonarr était configuré dans /home/marc/radarr (qui
  # contient AUSSI radarr.db, reste d'un ancien Radarr, laissé en place). On ne
  # copie que les données de Sonarr, pas config.xml : il est régénéré depuis les
  # réglages Nix ci-dessus (port 8006, urlbase localhost), alors que celui du
  # dossier partagé portait la config du dernier service qui l'avait écrit.
  systemd.services.sonarr-data-migrate = {
    description = "Migration du dossier de données de Sonarr (~/radarr -> ~/sonarr)";
    wantedBy = [ "multi-user.target" ];
    before = [ "sonarr.service" ];
    unitConfig.ConditionPathExists = "!/home/marc/sonarr/.migration-done";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      ${pkgs.coreutils}/bin/install -d -o marc -g users -m 0700 /home/marc/sonarr
      for f in sonarr.db sonarr.db-shm sonarr.db-wal logs.db logs.db-shm logs.db-wal; do
        if [ -e "/home/marc/radarr/$f" ]; then
          ${pkgs.coreutils}/bin/cp -a "/home/marc/radarr/$f" "/home/marc/sonarr/$f"
        fi
      done
      for d in Backups asp Sentry logs; do
        if [ -d "/home/marc/radarr/$d" ]; then
          ${pkgs.coreutils}/bin/cp -a "/home/marc/radarr/$d" /home/marc/sonarr/
        fi
      done
      ${pkgs.coreutils}/bin/chown -R marc:users /home/marc/sonarr
      ${pkgs.coreutils}/bin/touch /home/marc/sonarr/.migration-done
    '';
  };

  # DIAGNOSTIC TEMPORAIRE (a retirer) : exhume la base Jellyfin (clés API,
  # utilisateurs) et le config.xml de Radarr, root-only, vers un dossier
  # lisible par hermes, pour pouvoir piloter les deux en solo.
  system.activationScripts.mediaDiag = ''
    ${pkgs.coreutils}/bin/install -d -o hermes -g hermes -m 0750 /var/lib/hermes/x-media
    for f in /var/lib/jellyfin/data/jellyfin.db /var/lib/jellyfin/data/jellyfin.db-wal /var/lib/jellyfin/data/jellyfin.db-shm; do
      if [ -e "$f" ]; then ${pkgs.coreutils}/bin/cp -a "$f" /var/lib/hermes/x-media/; fi
    done
    for f in /var/lib/radarr/.config/Radarr/config.xml /home/marc/sonarr/config.xml /var/lib/prowlarr/config.xml; do
      if [ -e "$f" ]; then ${pkgs.coreutils}/bin/cp -a "$f" "/var/lib/hermes/x-media/$(echo "$f" | tr '/' '_')"; fi
    done
    ${pkgs.coreutils}/bin/chown -R hermes:hermes /var/lib/hermes/x-media
    ${pkgs.coreutils}/bin/chmod -R u+rwX,go-rwx /var/lib/hermes/x-media
  '';
}