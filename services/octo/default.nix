# services/octo/default.nix
# Octo (github.com/winters27/octo, GPL-3, Rust) : proxy OpenSubsonic devant
# Navidrome. Il ajoute ce que Navidrome ne sait pas faire :
#   - chercher hors bibliotheque (Deezer + YouTube Music + Last.fm) et jouer
#     tout de suite un titre absent, en preview YouTube via yt-dlp ;
#   - une radio qui apprend des ecoutes (Last.fm, YouTube Music, ListenBrainz),
#     servie aux clients Subsonic comme des stations / playlists ;
#   - surtout : telecharger sur un coeur (ou un "+") le titre absent, le taguer
#     et le deposer dans la bibliotheque que Navidrome scanne.
# Navidrome n'a pas d'OIDC ni de source audio externe : un plugin (capacites
# metadata/scrobbler/lyrics/sonicSimilarity) ne peut PAS rendre jouable un
# fichier absent. C'est ce trou que ce proxy comble.
#
# Deux conteneurs OCI (podman, virtualisation.oci-containers, meme schema que
# services/aonsoku) :
#   - octo             : l'app + son API Subsonic, publiee sur 127.0.0.1:5274
#                        (octo.marcpartensky.com) ; il joint Navidrome par
#                        host.containers.internal:4533, donc le service local
#                        reste introuchable depuis le LAN ;
#   - octo-yt-dlp-shim : yt-dlp + deno (runtime JS exige par YouTube) derriere
#                        /search et /stream, jamais publie, joint par nom sur
#                        un reseau podman dedie (le reseau par defaut de podman
#                        n'a pas de DNS).
#
# Choix deliberes :
#   - DownloadSource = YouTube : un coeur telecharge le M4A/MP3 YouTube
#     directement. Pas de slskd, donc pas de compte Soulseek ni de port 50300
#     a ouvrir ; a passer a Soulseek/Lidarr plus tard si marc veut du FLAC.
#   - Pas d'octo-sonic (Sounds alike) : il decode la bibliotheque en continu,
#     et tower heberge deja la pile TTS de marc sur le CPU.
{
  config,
  lib,
  pkgs,
  ...
}: let
  dataDir = "/var/lib/octo";
  # Bibliotheque partagee (groupe `media`, setgid) : les fichiers telecharges
  # heritent du groupe media et restent lisibles par navidrome/jellyfin.
  musicDir = "/srv/media/music";
  # Tag d'image : meme version pour les deux conteneurs (le shim et l'app
  # doivent rester alignes, cf. docker-compose upstream).
  tag = "2026.10.28";
in {
  # ── Reseau podman dedie ──────────────────────────────────────────────────
  # NixOS n'a pas d'option pour declarer un reseau podman : un oneshot le cree
  # (idempotent) et les deux unites de conteneur demarrent apres lui.
  systemd.services.podman-network-octo = {
    description = "Reseau podman `octo` (octo <-> yt-dlp-shim)";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    before = ["podman-octo.service" "podman-octo-yt-dlp-shim.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.podman}/bin/podman network exists octo ||
        ${pkgs.podman}/bin/podman network create octo
    '';
  };

  # ── Etat persistant ──────────────────────────────────────────────────────
  # Config Octo (settings.json ecrit par le dashboard, code de recuperation
  # admin) et caches yt-dlp (binaire auto-mis a jour, base de durees).
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
    "d ${dataDir}/config 0700 root root -"
    "d ${dataDir}/ytdlp-bin 0755 root root -"
    "d ${dataDir}/ytdlp-cache 0755 root root -"
    "d ${dataDir}/ytshim 0755 root root -"
  ];

  # ── Shim yt-dlp (recherche + resolution de flux) ─────────────────────────
  virtualisation.oci-containers.containers.octo-yt-dlp-shim = {
    image = "ghcr.io/winters27/octo-yt-dlp-shim:${tag}";
    autoStart = true;
    extraOptions = [
      "--network=octo"
      "--umask=002"
    ];
    volumes = [
      # Les telechargements YouTube doivent atterrir la ou Navidrome scanne.
      "${musicDir}:/music"
      # Binaire yt-dlp hors de l'image : sa mise a jour survit a la recreation
      # du conteneur (YouTube casse un extracteur tous les mois).
      "${dataDir}/ytdlp-bin:/opt/ytdlp"
      "${dataDir}/ytdlp-cache:/root/.cache/yt-dlp"
      "${dataDir}/ytshim:/var/lib/ytshim"
    ];
    environment = {
      SHIM_THREADS = "32";
      MAX_CONCURRENT_YTDLP = "3";
      DOWNLOAD_ROOT = "/music";
      YTDLP_PATH = "/opt/ytdlp/yt-dlp";
      META_DB_PATH = "/var/lib/ytshim/meta.db";
      # visionos : URL de flux jouables tout de suite (les clients par defaut
      # de yt-dlp ne donnent une URL valide qu'apres 4 a 14 s).
      YTDLP_PLAYER_CLIENT = "visionos";
    };
  };

  # ── Octo ─────────────────────────────────────────────────────────────────
  virtualisation.oci-containers.containers.octo = {
    image = "ghcr.io/winters27/octo:${tag}";
    autoStart = true;
    dependsOn = ["octo-yt-dlp-shim"];
    extraOptions = [
      "--network=octo"
      # host.containers.internal -> IP de l'hote vue depuis le pont podman :
      # c'est ce qui permet de joindre Navidrome en 127.0.0.1:4533 sans passer
      # par le domaine public (et donc sans dependre de newt).
      "--add-host=host.containers.internal:host-gateway"
      "--publish=127.0.0.1:5274:8080"
      # setgid sur la bibliotheque + umask 002 : fichiers root:media en 664,
      # donc lisibles par navidrome et par jellyfin.
      "--umask=002"
    ];
    volumes = [
      "${musicDir}:/music"
      "${dataDir}/config:/app/config"
    ];
    environment = {
      ASPNETCORE_ENVIRONMENT = "Production";
      TZ = "Europe/Paris";

      # --- Navidrome en amont ---
      Subsonic__Url = "http://host.containers.internal:4533";
      # Stream : rien n'est mis en cache disque, la bibliotheque fait foi.
      Subsonic__StorageMode = "Stream";
      # Un coeur telecharge une copie permanente : depuis YouTube ici.
      Subsonic__DownloadSource = "YouTube";
      Subsonic__DownloadOnStar = "true";
      Subsonic__DownloadAlbumOnStar = "true";
      # Ne jamais retelecharger un titre deja present.
      Subsonic__SkipOwnedSongs = "true";
      # Artist/Album, comme la bibliotheque existante.
      Subsonic__FolderStructure = "Organized";
      # Recherche au-dela de la bibliotheque (le coeur du besoin).
      Subsonic__EnableSearchDiscovery = "true";
      Library__DownloadPath = "/music";

      # --- Preview YouTube ---
      YouTube__ShimUrl = "http://octo-yt-dlp-shim:8080";

      # --- Radio : sources sans cle d'API ---
      RadioSources__YouTubeMusic = "true";
      RadioSources__ListenBrainz = "true";
      # Pas d'octo-sonic : Sounds alike est desactive (voir l'en-tete).
      RadioSources__SoundsAlike = "false";
      GeneratedPlaylists__PopularNow = "true";

      # --- Metadonnees ---
      Metadata__FetchLyrics = "true";
      # lrclib et lyricsovh seulement : kugou/netease sont des API non
      # officielles, hors de question de les interroger par defaut.
      Metadata__LyricsSources = "song,lrclib,lyricsovh";
      Metadata__ReplayGain = "true";

      Admin__SignIn = "required";
      Updates__Check = "true";
    };
  };

  # ── Exposition publique ──────────────────────────────────────────────────
  # octo.marcpartensky.com -> 127.0.0.1:5274. Le domaine navidrome reste
  # pointe sur Navidrome : aucun client existant ne bouge, Octo s'ajoute.
  # /rest/* et /share/* sortent du gate SSO, sinon les clients Subsonic
  # (Feishin, Symfonium, apps mobiles) ne peuvent pas suivre la redirection
  # Pangolin : meme contrainte que pour navidrome.
  services.newt.blueprint.proxy-resources.octo = {
    name = "octo";
    protocol = "http";
    full-domain = "octo.marcpartensky.com";
    auth.sso-enabled = true;
    rules = [
      {
        action = "allow";
        match = "path";
        value = "rest/*";
      }
      {
        action = "allow";
        match = "path";
        value = "share/*";
      }
    ];
    targets = [
      {
        hostname = "127.0.0.1";
        port = 5274;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = 5274;
          # / renvoie un 302 vers /app/ ; /health repond 200 en direct.
          path = "/health";
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
}
