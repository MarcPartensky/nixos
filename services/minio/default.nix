# services/minio/default.nix
{
  pkgs,
  config,
  lib,
  ...
}: {
  # ---------------------------------------------------------------------------
  # SECRETS SOPS
  # ---------------------------------------------------------------------------
  sops.secrets = {
    "minio/root_user" = {
      key = "minio_root_user";
    };
    "minio/root_password" = {
      key = "minio_root_password";
    };
  };

  # rootCredentialsFile attend un fichier env avec MINIO_ROOT_USER + MINIO_ROOT_PASSWORD
  sops.templates."minio-credentials" = {
    content = ''
      MINIO_ROOT_USER=${config.sops.placeholder."minio/root_user"}
      MINIO_ROOT_PASSWORD=${config.sops.placeholder."minio/root_password"}
    '';
    owner = "minio";
    group = "minio";
  };

  # ---------------------------------------------------------------------------
  # CONFIGURATION MINIO
  # ---------------------------------------------------------------------------
  services.minio = {
    enable = true;
    # Stockage des objets - adapte le chemin selon ta machine (ZFS dataset ?)
    dataDir = ["/var/lib/minio/data"];
    # API S3 - écoute uniquement en local, Traefik fait le reverse proxy
    listenAddress = "127.0.0.1:9000";
    # Console web MinIO
    consoleAddress = "127.0.0.1:9001";
    # Fichier généré par sops.templates ci-dessus
    rootCredentialsFile = config.sops.templates."minio-credentials".path;
  };

  # ---------------------------------------------------------------------------
  # TRAEFIK - labels si tu passes par docker labels, sinon fichier dynamique
  # Ici : config statique via fichier (cohérent avec ton setup Pangolin/Traefik)
  # ---------------------------------------------------------------------------
  # Si tu as un services.traefik.dynamicConfigOptions dans ta conf :
  #
  # services.traefik.dynamicConfigOptions.http = {
  #   routers.minio-api = {
  #     rule = "Host(`s3.vps.marcpartensky.com`)";
  #     entryPoints = [ "websecure" ];
  #     service = "minio-api";
  #     tls.certResolver = "letsencrypt";
  #   };
  #   routers.minio-console = {
  #     rule = "Host(`minio.vps.marcpartensky.com`)";
  #     entryPoints = [ "websecure" ];
  #     service = "minio-console";
  #     tls.certResolver = "letsencrypt";
  #   };
  #   services.minio-api.loadBalancer.servers = [
  #     { url = "http://127.0.0.1:9000"; }
  #   ];
  #   services.minio-console.loadBalancer.servers = [
  #     { url = "http://127.0.0.1:9001"; }
  #   ];
  # };
}
