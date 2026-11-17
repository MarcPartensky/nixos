# services/immich/default.nix
# Immich : l'interface photos/videos (timeline, visages, recherche, carte,
# applis mobiles). Verdict du comparatif SOTA : c'est l'etat de l'art, 119k
# etoiles, release v3.4.1 upstream.
#
# PAQUET : celui du pin 26.05 est immich 2.7.5, marque `insecure` par nixpkgs
# (deux CVE : CVE-2026-59258, CVE-2026-82272, et 2.x ne recoit plus de
# correctifs). On prend donc immich 3.2.2 depuis l'input `unstable` du flake :
# le module nixpkgs 26.05 pilote le paquet sans probleme (memes variables
# d'environnement, passthru `machine-learning` present).
#
# Architecture decidee : la SOURCE DE VERITE reste l'arbre ZFS
# /home/marc/media/photos (dataset `nixos/marc/media`), Garage en est le miroir
# de sauvegarde, et Immich ne fait que L'INDEXER via une bibliotheque externe.
# Aucune copie, aucun reupload : Immich n'a pas de backend S3 (feature request
# #30191 toujours ouverte), donc « Immich avec Garage en backend » n'existe pas.
#
# L'arbre est expose aux services par un bind READ-ONLY sur /srv/photos :
#   - /home est protege (ProtectHome=true) dans les unites systemd, un bind
#     explicite sur /srv contourne ca proprement ;
#   - le mode ro garantit qu'aucune appli ne peut ecrire dans l'arbre partage
#     avec Syncthing et le miroir Garage (pas de sidecar, pas de vignette).
#
# Droits : les dossiers sont 2770 marc:photos et les fichiers hermes:photos,
# donc l'utilisateur `immich` est ajoute au groupe `photos` pour lire.
# PrivateUsers est desactive sur immich-server uniquement : sous PrivateUsers,
# l'appartenance a un groupe hote n'est pas mappee et la lecture echouerait.
#
# Ressources : ML (visages, recherche) active, sur CPU. tower n'a ni CUDA ni
# ROCm. Le service tourne en Slice system-immich.slice, donc separable et
# mesurable (systemd-cgtop -M system-immich.slice).
{ config, lib, pkgs, inputs, ... }:
let
  photosSource = "/home/marc/media/photos";
  photosMount = "/srv/photos";

  # Files d'indexation couteuses (cf. la section « Indexation uniquement la
  # nuit » plus bas pour la raison et le planning).
  immichHeavyQueues = [
    # `ocr` ajoutee le 14/11/2026 : absente de cette liste, elle tournait 24/7
    # (848 jobs en attente, 1 actif non stop) et c'est ELLE qui gardait le
    # service machine-learning a ~190 % d'un coeur en pleine journee, alors que
    # toutes les autres files etaient bien en pause. Une file oubliee ici suffit
    # a annuler le planning : verifier la liste /api/jobs apres chaque montée
    # de version d'immich, qui peut en ajouter.
    "ocr"
    "thumbnailGeneration"
    "metadataExtraction"
    "videoConversion"
    "faceDetection"
    "facialRecognition"
    "smartSearch"
    "duplicateDetection"
  ];

  # Pilotage des files par l'API HTTP d'immich. La cle API vit dans un fichier
  # (cree une fois par l'admin dans /var/lib/hermes/immich-jobs/api-key,
  # propriete de hermes, lisible par root). Sans ce fichier les unites ne font
  # rien et ne cassent pas le boot. L'idempotence est portee par immich : une
  # file deja en pause ignore un second "pause".
  immichJobsScript = pkgs.writeShellScript "immich-jobs-schedule" ''
    set -eu
    mode="''${1:-auto}"
    key_file=/var/lib/hermes/immich-jobs/api-key

    # Attendre que l'API reponde (le serveur met ~20 s a demarrer, et ce script
    # peut etre lance juste apres lui). 5 min max, puis on abandonne proprement.
    # 120 s ne suffisaient pas : au boot du 17/11/2026 l'unite a echoue alors
    # que la machine venait de redemarrer et que deux autres services bouclaient.
    i=0
    while ! curl -sf -o /dev/null http://127.0.0.1:2283/api/server/ping; do
      i=$((i + 1))
      if [ "$i" -ge 150 ]; then
        echo "immich-jobs: API injoignable apres 300 s, abandon" >&2
        exit 1
      fi
      sleep 2
    done

    if [ ! -r "$key_file" ]; then
      # Amorçage : sans cle API, on la cree avec le compte admin (mot de passe
      # laisse dans un fichier root-lisible). Sinon la cle n'existerait qu'en
      # la creant a la main, et les files resteraient actives a vie.
      pw_file=/var/lib/hermes/immich-jobs/admin-password
      if [ -r "$pw_file" ]; then
        pw=$(cat "$pw_file")
        tok=$(curl -s -X POST -H 'Content-Type: application/json' \
          -d "{\"email\":\"marc@marcpartensky.com\",\"password\":\"$pw\"}" \
          http://127.0.0.1:2283/api/auth/login | jq -r '.accessToken // empty')
        if [ -n "$tok" ]; then
          secret=$(curl -s -X POST -H "Authorization: Bearer $tok" \
            -H 'Content-Type: application/json' \
            -d '{"name":"hermes-indexation-nuit","permissions":["all"]}' \
            http://127.0.0.1:2283/api/api-keys | jq -r '.secret // empty')
          if [ -n "$secret" ]; then
            umask 077
            printf '%s' "$secret" > "$key_file"
            echo "immich-jobs: cle API creee dans $key_file"
          fi
        fi
      fi
    fi

    if [ ! -r "$key_file" ]; then
      echo "immich-jobs: pas de cle API ($key_file), rien a faire" >&2
      exit 0
    fi

    case "$mode" in
      auto)
        h=$(date +%-H)
        if [ "$h" -ge 4 ] && [ "$h" -lt 8 ]; then action=resume; else action=pause; fi
        echo "immich-jobs: mode auto a ''${h}h -> $action"
        ;;
      pause|resume) action="$mode" ;;
      *)
        echo "immich-jobs: mode inconnu '$mode' (auto|pause|resume)" >&2
        exit 2
        ;;
    esac

    key=$(cat "$key_file")
    for q in ${lib.concatStringsSep " " immichHeavyQueues}; do
      code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
        -H "x-api-key: $key" -H 'Content-Type: application/json' \
        -d "{\"command\":\"$action\"}" \
        "http://127.0.0.1:2283/api/jobs/$q" || echo 000)
      echo "immich-jobs: $q -> $action ($code)"
    done
  '';
in
{
  fileSystems."${photosMount}" = {
    device = photosSource;
    fsType = "none";
    options = [
      "bind"
      "ro"
      "x-systemd.requires-mounts-for=${photosSource}"
    ];
  };

  # L'utilisateur `immich` est cree par le module nixpkgs seulement quand le
  # service est actif : on conditionne l'ajout au groupe photos, sinon l'eval
  # casse des que services.immich.enable = false.
  users.users.immich = lib.mkIf config.services.immich.enable {
    extraGroups = [ "photos" ];
  };

  services.immich = {
    # Marc avait coupe le service a 13h41 (le switch de 13h29 l'avait rallume et
    # il relancait l'indexation en pleine journee). Rallume ici parce que le
    # planning nocturne est desormais en place : `immich-jobs-boot` met les
    # files couteuses en pause des le demarrage hors fenetre 01:00-08:00, donc
    # l'UI repond sans faire tourner le CPU. Repasser a false pour couper sec.
    enable = true;
    host = "127.0.0.1";
    port = 2283;
    package = inputs.unstable.legacyPackages.${pkgs.system}.immich;
    # Bibliotheque propre d'Immich (uploads depuis l'appli mobile, vignettes,
    # videos transcodees). Sur le pool racine (191 Go libres) et non sur le
    # dataset media, dont le quota de 150 G doit rester aux photos.
    mediaLocation = "/var/lib/immich";
    database.enable = true;
    redis.enable = true;
    machine-learning.enable = true;
    environment = {
      TZ = "America/New_York";
      # PAS de IMMICH_TELEMETRY_INCLUDE : immich 3.x valide cette variable contre
      # une liste d'evenements et "none" n'en fait plus partie -> le serveur
      # refuse de demarrer ("Invalid telemetry found: none", boucle de crash au
      # premier switch, 14/11/2026). Sans la variable, la telemetrie est
      # simplement desactivee.
    };
  };

  # Immich lit un dossier, il n'a aucun endpoint S3 : la bibliotheque externe
  # se declare dans l'UI (Administration > External Libraries) sur /srv/photos.
  systemd.services.immich-server.serviceConfig = {
    PrivateUsers = lib.mkForce false;
    BindReadOnlyPaths = [ "${photosMount}:/srv/photos" ];

    # ── Reseau ferme : immich est un ilot ──────────────────────────────────
    # Filtre eBPF par cgroup (systemd 260) : le serveur ne peut joindre que le
    # loopback (Pangolin, et le ML quand il vivait ici) et l'IP tailscale du
    # portable qui heberge le ML GPU. Rien d'autre de tower ne lui est
    # joignable, meme si une faille ouvrait une socket sortante. Les sockets
    # unix (PostgreSQL /run/postgresql, redis /run/redis-immich) ne sont pas
    # filtres par ces regles, la base et le cache ne sont donc pas concernes.
    # Ce qui sort vers le tailnet sort par le tun, tailscaled encapsule hors du
    # cgroup : le filtre n'a pas a connaitre le chemin reseau reel (DIRECT ou
    # relais DERP).
    IPAddressDeny = "any";
    IPAddressAllow = [
      "127.0.0.1/32" # Pangolin (newt) et le ML en local
      "::1/128"
      "100.100.100.100/32" # MagicDNS, pour resoudre le nom du portable
      "100.64.0.4/32" # portable : immich-machine-learning sur GPU
    ];
  };

  # ── Indexation uniquement la nuit ─────────────────────────────────────────
  # Un premier scan de l'arbre (23 600 fichiers) lance thumbnails, metadata,
  # detection de visages et smart search : mesure du 14/11/2026, ~1,8 coeur
  # pendant plus de 8 min et load average > 20 sur tower, ce qui a fait
  # arreter le service a la main (deux fois). Marc veut donc que ces files ne
  # tournent qu'entre 04:00 et 08:00 (fenetre avancee a 04:00 le 14/11/2026, il
  # voulait l'indexation a 4 h du matin) ; le serveur, lui, reste joignable
  # (UI, timeline, uploads).
  #
  # Trois declencheurs, parce que le planning seul ne suffit pas : immich
  # demarre TOUJOURS avec ses files actives, donc un simple switch a 13h
  # relancait l'indexation jusqu'au lendemain 08:00 (vecu). D'ou le service
  # `immich-jobs-boot`, wantedBy multi-user.target : il applique l'etat
  # correct des le demarrage (et a chaque switch qui l'active), y compris en
  # deplacant le calcul d'heure dans le script (`auto`).

  systemd.services.immich-jobs-pause = {
    description = "Immich : met les files d'indexation en pause (journee)";
    after = ["immich-server.service"];
    wants = ["immich-server.service"];
    # Le PATH d'une unite systemd ne contient ni curl ni jq : sans cette ligne
    # le script boucle sur "API injoignable" alors que le serveur repond.
    path = [pkgs.curl pkgs.jq pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${immichJobsScript} pause";
    };
  };

  systemd.services.immich-jobs-resume = {
    description = "Immich : relance les files d'indexation (nuit)";
    after = ["immich-server.service"];
    wants = ["immich-server.service"];
    path = [pkgs.curl pkgs.jq pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${immichJobsScript} resume";
    };
  };

  # Etat correct au demarrage : pause sauf entre 04:00 et 08:00.
  systemd.services.immich-jobs-boot = {
    description = "Immich : applique l'etat des files selon l'heure (04-08 = actif)";
    after = ["immich-server.service"];
    wants = ["immich-server.service"];
    wantedBy = ["multi-user.target"];
    path = [pkgs.curl pkgs.jq pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${immichJobsScript} auto";
    };
  };

  systemd.timers.immich-jobs-pause = {
    description = "Immich : fenetre d'indexation 04:00 -> 08:00 (pause a 08:00)";
    wantedBy = ["timers.target"];
    # Persistent = true sur la pause seulement : apres un boot en journee, la
    # pause manquee se rejoue tout de suite ; la reprise, elle, attend la nuit
    # suivante (sinon un boot a 12:00 relancerait l'indexation en pleine
    # journee, ce que marc refuse).
    timerConfig = {
      OnCalendar = "*-*-* 08:00:00";
      Persistent = true;
    };
  };

  systemd.timers.immich-jobs-resume = {
    description = "Immich : reprise des files a 04:00";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = false;
    };
  };

  # Force le (re)demarrage du serveur au prochain switch : sans ca, une unite
  # arretee a la main le reste, et ce module ne ferait que poser des timers
  # sans service a piloter.
  systemd.services.immich-server.restartTriggers = [
    (pkgs.writeText "immich-job-schedule" "night-only-v4-4h")
  ];
}
