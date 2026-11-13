# deploy/containers.nix
# Source de verite des conteneurs SORTIS de la conf hote.
#
# Pourquoi : changer une image, un port ou une variable d'environnement ne doit
# plus couter un eval de la conf NixOS de tower (90 s a vide, 4 a 5 min sous
# charge) ni une nouvelle generation. `just deploy <nom>` rend un fichier
# quadlet podman et redemarre l'unite. Aucun nixos-rebuild n'est lance.
#
# Ce fichier n'est PAS importe par la conf hote : il n'entre dans aucun eval de
# nixosConfigurations. Il est expose par le flake sous `deploy.containers`.
#
# Ordre de migration, une seule fois par service et jamais a moitie :
#   1. `just deploy <nom>` : le quadlet est pose, le conteneur tourne.
#   2. seulement ensuite, retirer le bloc
#      `virtualisation.oci-containers.containers.<nom>` du module, et changer
#      `migrated` en true ici.
# Inverser l'ordre supprime le conteneur au prochain switch.
#
# Ce qui RESTE dans la conf hote apres migration :
#   - la route newt/Pangolin et les assertions d'exposition ;
#   - les declarations sops.templates / sops.secrets, parce que le quadlet lit
#     le fichier rendu par sops-nix (/run/secrets/rendered/<nom>.env). Aucun
#     secret n'est ecrit dans ce depot ni dans le quadlet.
#
# Non migrable pour l'instant : docs-compare/wikijs, dont le config.yml est un
# fichier genere par nix dans la conf hote (il faudrait le sortir du module).
{
  # ── Migres (module deja retire de la conf hote) ────────────────────────

  # ── A migrer (etape 1 faite a la main, etape 2 pas encore) ─────────────

  shlink-web-client = {
    migrated = true;
    description = "Client web d'administration Shlink";
    image = "docker.io/shlinkio/shlink-web-client:4.9.0";
    publish = ["127.0.0.1:8100:8080"];
    env = {
      SHLINK_SERVER_URL = "https://s.marcpartensky.com";
      SHLINK_SERVER_NAME = "marcpartensky";
    };
    health = {
      cmd = "wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1";
      interval = "30s";
      timeout = "10s";
      retries = 3;
    };
  };

  aonsoku = {
    migrated = true;
    description = "Client Subsonic pour Navidrome";
    image = "ghcr.io/victoralvesf/aonsoku:latest";
    publish = ["127.0.0.1:8099:8080"];
    env = {
      SERVER_URL = "https://navidrome.marcpartensky.com";
      HIDE_SERVER = "true";
      SERVER_TYPE = "navidrome";
      APP_THEME = "catppuccin-mocha";
    };
    health = {
      cmd = "wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1";
      interval = "30s";
      timeout = "10s";
      retries = 3;
    };
  };

  arr-mcp = {
    migrated = true;
    description = "Serveur MCP arr (Radarr, Sonarr, Jellyfin, Prowlarr)";
    image = "ghcr.io/bardesss/arr-mcp:latest";
    publish = ["127.0.0.1:6060:6060"];
  };

  nextcloud-mcp = {
    migrated = true;
    description = "Serveur MCP Nextcloud";
    image = "ghcr.io/cbcoutinho/nextcloud-mcp-server:latest";
    network = "host";
    cmd = ["--host" "127.0.0.1" "--port" "8710"];
    env = {
      NEXTCLOUD_HOST = "http://127.0.0.1:8083";
      MCP_DEPLOYMENT_MODE = "single_user_basic";
    };
    envFiles = ["/run/secrets/nextcloud_mcp_env"];
  };

  reactive-resume = {
    migrated = false;
    description = "Generateur de CV (Pangolin cv.marcpartensky.com)";
    image = "docker.io/amruthpillai/reactive-resume:v5.2";
    network = "host";
    unitAfter = ["network-online.target" "postgresql.service"];
    volumes = ["/var/lib/reactive-resume/data:/app/data"];
    envFiles = ["/run/secrets/rendered/reactive-resume.env"];
    health = {
      cmd = "node -e \"fetch('http://127.0.0.1:8098/api/health').then((r) => { if (!r.ok) process.exit(1); }).catch(() => process.exit(1));\"";
      interval = "30s";
      timeout = "10s";
      retries = 3;
    };
  };

  shlink = {
    migrated = false;
    description = "Raccourcisseur d'URL Shlink (API + redirections publiques)";
    image = "docker.io/shlinkio/shlink:stable";
    network = "host";
    unitAfter = ["network-online.target" "postgresql.service"];
    volumes = ["/var/lib/shlink/data:/etc/shlink/data"];
    envFiles = ["/run/secrets/rendered/shlink.env"];
    # Pas de healthcheck dans le conteneur : l'image ne garantit ni curl ni
    # wget. La sante est verifiee par Pangolin sur /rest/health.
  };

  # Deux conteneurs sur un reseau podman dedie, aucune publication d'hote pour
  # surrealdb : le script cree le reseau s'il manque.
  open-notebook-surreal = {
    migrated = false;
    description = "Base SurrealDB d'Open Notebook";
    image = "docker.io/surrealdb/surrealdb:v2";
    networks = ["open-notebook"];
    user = "root";
    volumes = ["/var/lib/open-notebook/surreal:/mydata"];
    cmd = ["start" "--log" "info" "--user" "root" "--pass" "root" "rocksdb:/mydata/mydatabase.db"];
  };

  open-notebook = {
    migrated = false;
    description = "Open Notebook (UI + API)";
    image = "docker.io/lfnovo/open_notebook:v1-latest";
    networks = ["open-notebook"];
    publish = ["127.0.0.1:8502:8502" "127.0.0.1:5055:5055"];
    volumes = ["/var/lib/open-notebook/data:/app/data"];
    env = {
      API_URL = "https://notebook.marcpartensky.com";
    };
    envFiles = ["/run/secrets/rendered/open-notebook.env"];
  };
}
