# services/open-notebook/default.nix
# Open Notebook (github.com/lfnovo/open-notebook), clone FOSS de NotebookLM,
# sur notebook.marcpartensky.com : sources, chat avec citations, podcasts multi-voix.
#
# Pas de paquet nixpkgs (Python/FastAPI + Next.js + SurrealDB) : conteneurs OCI
# via podman, même pattern que services/reactive-resume et services/chhoto.
#
# Réseau et ports (contraintes réelles de tower, vérifiées) :
#   - deux conteneurs sur un réseau podman dédié `open-notebook` ;
#   - SurrealDB n'est JAMAIS publié sur l'hôte : le port 8000 est déjà occupé
#     par un autre service et n'a pas besoin de l'être, l'app le rejoint par DNS
#     interne (ws://open-notebook-surreal:8000/rpc) ;
#   - l'UI (8502) et l'API (5055) du conteneur sont publiées en loopback sur
#     8555 et 9601 (8502 et 8000 sont pris sur tower) ;
#   - exposition publique uniquement via Pangolin/newt, derrière le SSO Zitadel.
{ config, lib, pkgs, ... }:
let
  portUi  = 8555;   # hôte -> 8502 (UI)
  portApi = 9601;   # hôte -> 5055 (REST API, loopback uniquement, outillage Hermes)
in
{
  # Clé qui chiffre les clés de providers (OpenRouter, etc.) stockées dans l'app.
  sops.secrets."open-notebook/encryption_key" = {
    sopsFile = ../../secrets/open-notebook.yml;
  };

  # SurrealDB reste en root:root volontairement : il n'est atteignable que depuis
  # le réseau interne du conteneur, jamais publié sur l'hôte, et l'app est derrière
  # le SSO. Le secret sops ne porte donc que la clé de chiffrement applicative.
  sops.templates."open-notebook.env" = {
    mode = "0400";
    content = ''
      OPEN_NOTEBOOK_ENCRYPTION_KEY=${config.sops.placeholder."open-notebook/encryption_key"}
      SURREAL_URL=ws://open-notebook-surreal:8000/rpc
      SURREAL_USER=root
      SURREAL_PASSWORD=root
      SURREAL_NAMESPACE=open_notebook
      SURREAL_DATABASE=open_notebook
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/open-notebook 0755 root root -"
    "d /var/lib/open-notebook/surreal 0755 root root -"
    # 0777 : l'uid interne de l'image open_notebook est inconnu ; le volume
    # doit rester inscriptible quel que soit l'utilisateur adopté par le process.
    "d /var/lib/open-notebook/data 0777 root root -"
  ];

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.oci-containers.backend = "podman";

  # Réseau podman dédié, créé avant les conteneurs (idempotent).
  systemd.services.open-notebook-network = {
    wantedBy = [ "multi-user.target" ];
    before = [ "podman-open-notebook-surreal.service" "podman-open-notebook.service" ];
    path = [ pkgs.podman ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${pkgs.podman}/bin/podman network exists open-notebook || ${pkgs.podman}/bin/podman network create open-notebook
    '';
  };

  virtualisation.oci-containers.containers."open-notebook-surreal" = {
    image = "docker.io/surrealdb/surrealdb:v2";
    autoStart = true;
    user = "root";
    networks = [ "open-notebook" ];   # aucune publication hôte
    volumes = [ "/var/lib/open-notebook/surreal:/mydata" ];
    cmd = [ "start" "--log" "info" "--user" "root" "--pass" "root" "rocksdb:/mydata/mydatabase.db" ];
    extraOptions = [ "--pull=newer" ];
  };

  virtualisation.oci-containers.containers.open-notebook = {
    image = "docker.io/lfnovo/open_notebook:v1-latest";
    autoStart = true;
    networks = [ "open-notebook" ];
    ports = [
      "127.0.0.1:${toString portUi}:8502"
      "127.0.0.1:${toString portApi}:5055"
    ];
    volumes = [ "/var/lib/open-notebook/data:/app/data" ];
    environmentFiles = [ config.sops.templates."open-notebook.env".path ];
    # Sans API_URL, la route /config du front détecte l'hôte public ET y
    # recolle le port interne de l'API : le navigateur appelait
    # https://notebook.marcpartensky.com:5055, que Pangolin n'expose pas (seul
    # 443 -> 8555 existe), donc /notebooks restait vide. Avec l'origine
    # publique, le front appelle /api en same-origin et le rewrite Next.js
    # (INTERNAL_API_URL par défaut http://localhost:5055) joint l'API dans le
    # conteneur.
    environment = {
      API_URL = "https://notebook.marcpartensky.com";
    };
    extraOptions = [ "--pull=newer" ];
  };

  systemd.services.podman-open-notebook-surreal = {
    after = [ "open-notebook-network.service" ];
    requires = [ "open-notebook-network.service" ];
  };

  systemd.services.podman-open-notebook = {
    after = [ "network-online.target" "open-notebook-network.service" "podman-open-notebook-surreal.service" ];
    wants = [ "network-online.target" ];
    requires = [ "open-notebook-network.service" "podman-open-notebook-surreal.service" ];
  };

  # Ressource publique Pangolin/newt : notebook.marcpartensky.com -> UI loopback.
  # NOTE (provisioning provisoire) : si une ressource du même sous-domaine a déjà
  # été créée via l'API d'intégration (déploiement provisoire hors nix), la
  # supprimer au dashboard PANGOLIN avant ce switch, sinon newt et l'API se
  # disputent le nom. Ce bloc est la forme durable et fait autorité une fois activé.
  services.newt.blueprint.proxy-resources.open-notebook = {
    name = "open-notebook";
    protocol = "http";
    full-domain = "notebook.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        hostname = "127.0.0.1";
        port = portUi;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = portUi;
          path = "/";
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

  # Garde-fou : jamais de port ouvert au LAN, exposition = Pangolin/newt + boucle locale.
  assertions = [
    {
      assertion = !(lib.elem portUi config.networking.firewall.allowedTCPPorts)
               && !(lib.elem portApi config.networking.firewall.allowedTCPPorts);
      message = "open-notebook : 8555/9601 ne doivent pas être ouverts au firewall (loopback + Pangolin uniquement).";
    }
  ];
}
