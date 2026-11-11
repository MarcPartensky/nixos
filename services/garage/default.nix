# services/garage/default.nix
# Garage : stockage objet S3 (Rust, deuxfleurs) pour les artifacts de build
# (APK, IPA, archives : ce que winnie et hermes-mobile deposent dans le bucket
# `artifacts`) + le MCP S3 qui les pilote depuis hermes.
#
# Remplace RustFS (retire le 2026-11-11) : rustfs passait ~1 coeur en rafales de
# walk_dir au repos (mesure atop : 96 a 113 % d'un coeur par echantillon de 10 s
# sans aucun client) pour un usage mono-machine. Garage est un binaire unique,
# sans scanner d'objets, avec un mode single-node.
#
# Ports (loopback seul, jamais exposes au firewall) :
#   - 127.0.0.1:3900 : API S3
#   - 127.0.0.1:3901 : RPC inter-noeuds (une seule machine ici)
#   - 127.0.0.1:3903 : API d'admin (garage CLI)
#
# Secrets : generes a l'activation dans /var/lib/garage (rpc_secret en hex,
# admin_token), comme le JWT d'atticd : ce sont des secrets d'ETAT du service,
# pas des identifiants partages a saisir (hermes ne peut pas ecrire de fichier
# sops, il n'a pas la cle age de tower). La cle S3 applicative, elle, est creee
# par le bootstrap (unit oneshot idempotente) et deposee lisible par hermes
# dans /var/lib/garage/s3-key.env.
#
# Pas de console web : Garage n'en a pas. Les clients sont le MCP S3 et les CLI
# (rclone, aws). L'admin API (3903) reste en loopback.
{ config, lib, pkgs, ... }:
let
  stateDir = "/var/lib/garage";
  # Un bucket par source : le S3 n'a pas de vrais dossiers, un prefixe par
  # projet suffit pour les artifacts mais les photos viennent de sources
  # distinctes (camera, WhatsApp, Messenger) qu'on veut pouvoir isoler,
  # compter et sauvegarder separement.
  buckets = [
    "artifacts"
    "photos-camera"
    "photos-whatsapp"
    "photos-messenger"
    # Bucket PUBLIQUE, seul à avoir le mode website activé plus bas : tout
    # objet qu'on y met est lisible par qui connaît l'URL, sans signature ni
    # session. C'est ce bucket qui reçoit les fichiers partagés par lien court
    # (services/share-mcp). Ne jamais y déposer ce qui doit rester privé :
    # artifacts et photos-* restent, eux, inaccessibles en anonyme même si
    # l'endpoint web est joignable (Garage n'expose au public que les buckets
    # marqués website).
    "public"
  ];
  # Chemin du placeholder de santé : sert de sonde au healthcheck Pangolin
  # (Garage répond 404 sur la racine d'un bucket sans index.html, donc une
  # sonde sur /public/ marquerait la cible unhealthy et Pangolin la sortirait
  # du load-balancer).
  healthKey = "_health.txt";
  keyName = "hermes";

  # MCP S3 en stdio. `rustfs-mcp` (github:rustfs/mcp) est un client S3
  # GENERIQUE : il prend --endpoint-url et fait du path-style pour un endpoint
  # custom, donc il pilote Garage sans changement. Il n'est pas dans nixpkgs,
  # d'ou le buildRustPackage ; ses features par defaut (io-uring) exigent
  # tokio_unstable, comme dans le Dockerfile amont.
  s3-mcp = pkgs.rustPlatform.buildRustPackage {
    pname = "rustfs-mcp";
    version = "0.1.0";
    src = pkgs.fetchFromGitHub {
      owner = "rustfs";
      repo = "mcp";
      rev = "5126e9a87e53365c310d2f42d5e0cf4c30ef6a7c";
      hash = "sha256-qgdObysH4QiX4/QpTMk8Dg2IxqJVHSDYX28kLqaxTBE=";
    };
    cargoHash = "sha256-7MWyT7CzQRz+aMZvxWi19scVh6hvdtW1bmGthbIXb+M=";
    env.RUSTFLAGS = "--cfg tokio_unstable";
    doCheck = false;
    meta = {
      description = "MCP S3-compatible (client generique, pilote Garage)";
      homepage = "https://github.com/rustfs/mcp";
      license = lib.licenses.asl20;
      mainProgram = "rustfs-mcp";
    };
  };

  # Wrapper stdio : hermes spawn ce script, qui lit la cle applicative generee
  # par garage-bootstrap (jamais un secret en dur dans le store nix).
  mcpWrapper = pkgs.writeShellScript "garage-s3-mcp-hermes" ''
    set -euo pipefail
    # shellcheck disable=SC1091
    . ${stateDir}/s3-key.env
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
    exec ${lib.getExe s3-mcp} --endpoint-url http://127.0.0.1:3900
  '';
in
{
  services.garage = {
    enable = true;
    package = pkgs.garage;
    logLevel = "info";
    settings = {
      metadata_dir = "${stateDir}/meta";
      data_dir = "${stateDir}/data";
      db_engine = "sqlite";
      # Mono-noeud : pas de redondance a gerer, un seul disque.
      replication_factor = 1;
      consistency_mode = "consistent";
      rpc_bind_addr = "127.0.0.1:3901";
      rpc_public_addr = "127.0.0.1:3901";
      rpc_secret_file = "${stateDir}/rpc_secret";
      s3_api = {
        api_bind_addr = "127.0.0.1:3900";
        s3_region = "garage";
      };
      admin = {
        api_bind_addr = "127.0.0.1:3903";
        admin_token_file = "${stateDir}/admin_token";
      };
      # Endpoint HTTP « website » : sert en path-style /<bucket>/<cle> les
      # buckets marqués website (voir le bootstrap). Loopback seul, exposé au
      # public uniquement par la ressource Pangolin files.marcpartensky.com
      # (services/share-mcp), sans SSO puisque les liens courts pointent dessus.
      web = {
        bind_addr = "127.0.0.1:3902";
      };
    };
  };

  # Le module nixpkgs tourne en DynamicUser par defaut : les fichiers de
  # secrets generes a l'activation (root) seraient alors illisibles pour le
  # service. Utilisateur statique a la place, proprietaire de ses secrets.
  users.groups.garage = { };
  users.users.garage = {
    isSystemUser = true;
    group = "garage";
    home = stateDir;
    description = "Garage object storage";
  };

  systemd.services.garage.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "garage";
    Group = "garage";
  };

  # Secrets d'instance, generes une seule fois : les regenerer changerait le
  # rpc_secret et rendrait les donnees existantes illisibles.
  # Le dossier reste 0755 (traversable) : hermes doit pouvoir lire le
  # s3-key.env que le bootstrap y depose. Les secrets eux-memes sont 0400
  # garage, donc illisibles pour quiconque d'autre.
  system.activationScripts.garage-secrets = ''
    install -d -m 0755 -o garage -g garage ${stateDir}
    if [ ! -s ${stateDir}/rpc_secret ]; then
      umask 077
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${stateDir}/rpc_secret
      ${pkgs.openssl}/bin/openssl rand -base64 32 > ${stateDir}/admin_token
    fi
    chown garage:garage ${stateDir}/rpc_secret ${stateDir}/admin_token
    chmod 0400 ${stateDir}/rpc_secret ${stateDir}/admin_token
  '';

  # Bootstrap idempotent : layout du noeud, cle S3 applicative, bucket.
  # Le CLI `garage` lit /etc/garage.toml (pose par le module) et l'admin_token.
  systemd.services.garage-bootstrap = {
    description = "Garage : layout mono-noeud, cle S3 ${keyName}, buckets (artifacts, photos-*)";
    wantedBy = [ "multi-user.target" ];
    after = [ "garage.service" ];
    requires = [ "garage.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };
    path = [ pkgs.garage pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
    script = ''
      set -eu
      export GARAGE_CONFIG_FILE=/etc/garage.toml

      # Le service atteint l'etat "active" avant d'ecouter : attendre l'API admin.
      for _ in $(seq 1 30); do
        garage status >/dev/null 2>&1 && break
        sleep 2
      done

      node_id="$(garage node id -q | cut -d@ -f1)"
      layout="$(garage layout show 2>&1)"
      if ! printf '%s' "$layout" | grep -q "$node_id"; then
        garage layout assign -z dc1 -c 10G "$node_id"
        layout="$(garage layout show 2>&1)"
      fi
      if printf '%s' "$layout" | grep -qi "staged\|not yet committed"; then
        # `layout apply --version N` exige N = version courante + 1 : la version
        # initiale d'un cluster neuf n'est pas 0, donc la lire au lieu de coder 1.
        cur="$(printf '%s' "$layout" | sed -n 's/^Current cluster layout version: *//p' | tr -dc '0-9')"
        : ''${cur:=0}
        echo "$layout" >&2
        garage layout apply --version $((cur + 1))
      fi

      garage key info ${keyName} >/dev/null 2>&1 || garage key create ${keyName} >/dev/null
      for b in ${lib.concatStringsSep " " buckets}; do
        garage bucket create "$b" >/dev/null 2>&1 || true
        garage bucket allow --read --write "$b" --key ${keyName}
      done

      # Seul le bucket public passe en mode website (lecture anonyme via
      # l'endpoint web). Les autres restent privés : Garage ne sert en
      # anonyme que les buckets marqués website.
      garage bucket website --allow public

      # Identifiants S3 pour les clients non-root (wrapper MCP cote hermes).
      info="$(garage key info --show-secret ${keyName})"
      key_id="$(printf '%s\n' "$info" | sed -n 's/^Key ID: *//p')"
      key_secret="$(printf '%s\n' "$info" | sed -n 's/^Secret key: *//p')"
      if [ -z "$key_id" ] || [ -z "$key_secret" ]; then
        echo "garage: sortie de 'key info' inattendue, champs: $(printf '%s\n' "$info" | cut -d: -f1 | tr '\n' ' ')" >&2
        exit 1
      fi
      printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nAWS_REGION=garage\n' \
        "$key_id" "$key_secret" > ${stateDir}/s3-key.env
      chown hermes:hermes ${stateDir}/s3-key.env
      chmod 0400 ${stateDir}/s3-key.env
      unset key_secret info

      # Placeholder de santé du bucket public : le CLI garage ne sait pas
      # déposer d'objet, donc il passe par l'API S3 avec la clé qu'on vient
      # d'écrire. Sans lui, la sonde Pangolin tape une racine de bucket sans
      # index.html et reçoit 404 (cible unhealthy, retirée du load-balancer).
      set -a
      . ${stateDir}/s3-key.env
      set +a
      printf 'ok\n' | ${pkgs.awscli2}/bin/aws --endpoint-url http://127.0.0.1:3900 \
        s3 cp - "s3://public/${healthKey}" --content-type text/plain >/dev/null
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
    '';
  };

  services.hermes-agent.mcpServers.garage = {
    command = "${mcpWrapper}";
    timeout = 60;
  };
}
