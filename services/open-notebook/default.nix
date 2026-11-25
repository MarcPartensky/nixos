# services/open-notebook/default.nix
# Open Notebook (github.com/lfnovo/open-notebook), FOSS clone of NotebookLM,
# on notebook.marcpartensky.com: sources, chat with citations, multi-voice podcasts.
#
# No nixpkgs package (Python/FastAPI + Next.js + SurrealDB): OCI containers
# via podman, same pattern as services/reactive-resume and services/chhoto.
#
# Network and ports (real tower constraints, verified):
#   - two containers on a dedicated podman network `open-notebook`;
#   - SurrealDB is NEVER published on the host: port 8000 is already taken
#     by another service and does not need to be, the app reaches it via internal
#     DNS (ws://open-notebook-surreal:8000/rpc);
#   - the container's UI (8502) and API (5055) are published on loopback on
#     8556 and 9601 (8502 and 8000 are taken on tower);
#   - public exposure only via Pangolin/newt, behind Zitadel SSO.
#
# UI PORT MOVED FROM 8555 TO 8556 ON 17/11/2026 (night repair): 8555 is
# continuously occupied by a process not declared in this flake (neither the
# Android emulator -- confirmed in crash-loop even before launching qemu, cf.
# services/android-capture -- nor a known podman container). The bind 8555
# failed on every attempt (`listen tcp4 127.0.0.1:8555: bind: address
# already in use`), hence the permanent start-limit-hit. Moving the port is the
# safe fix, without depending on the squatter's identity.
{ config, lib, pkgs, ... }:
let
  portUi  = 8556;   # host -> 8502 (UI)
  portApi = 9601;   # host -> 5055 (REST API, loopback only, Hermes tooling)

  # Target of the bridge to Audiobookshelf: podcast library "Voix IA" and its
  # root folder, as read on the instance (GET /api/libraries).
  absLibraryId = "fc2a9873-12cf-4588-aff7-63a94ba50840";
  absFolderId  = "58896995-e385-40ff-9c3d-a9769965eb5c";
  absTitle     = "Open Notebook";

  absSync = pkgs.writers.writePython3Bin "on-abs-sync" {
    flakeIgnore = [ "E501" "W503" "E265" ];
  } (builtins.readFile ./abs_sync.py);
in
{
  # Key that encrypts the provider keys (OpenRouter, etc.) stored in the app.
  sops.secrets."open-notebook/encryption_key" = {
    sopsFile = ../../secrets/open-notebook.yml;
  };

  # SurrealDB stays as root:root deliberately: it is reachable only from
  # the container's internal network, never published on the host, and the app is behind
  # SSO. The sops secret therefore only carries the application encryption key.
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
    # 0777: the internal uid of the open_notebook image is unknown; the volume
    # must remain writable whatever user the process adopts.
    "d /var/lib/open-notebook/data 0777 root root -"
  ];

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.oci-containers.backend = "podman";

  # Dedicated podman network, created before the containers (idempotent).
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
    networks = [ "open-notebook" ];   # no host publication
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
    # Without API_URL, the front's /config route detects the public host AND
    # reattaches the API's internal port to it: the browser called
    # https://notebook.marcpartensky.com:5055, which Pangolin does not expose (only
    # 443 -> 8555 exists), so /notebooks stayed empty. With the public
    # origin, the front calls /api same-origin and the Next.js rewrite
    # (INTERNAL_API_URL default http://localhost:5055) reaches the API in the
    # container.
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

  # Open Notebook -> Audiobookshelf bridge. ABS has no pull API: it's
  # therefore a timer that pushes finished episodes into the "Open Notebook" item
  # of the "Voix IA" podcast library (/srv/media/audiobooks/voix-ia).
  # Idempotent via a state file under /var/lib/hermes/.hermes/state + via the
  # list of file names already known to ABS, so a restart or a
  # state loss does not duplicate episodes.
  systemd.services.on-abs-sync = {
    description = "Publishes new Open Notebook podcasts to Audiobookshelf";
    after = [ "podman-open-notebook.service" "audiobookshelf.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
      ExecStart = "${absSync}/bin/on-abs-sync --library-id ${absLibraryId} --folder-id ${absFolderId} --title \"${absTitle}\"";
    };
  };

  systemd.timers.on-abs-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "10min";
      Persistent = true;
    };
  };

  # Pangolin/newt public resource: notebook.marcpartensky.com -> UI loopback.
  # NOTE (temporary provisioning): if a resource of the same subdomain has already
  # been created via the integration API (temporary deployment outside nix),
  # delete it in the PANGOLIN dashboard before this switch, otherwise newt and the API
  # compete for the name. This block is the durable form and is authoritative once enabled.
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

  # Safeguard: never a port open to the LAN, exposure = Pangolin/newt + loopback.
  assertions = [
    {
      assertion = !(lib.elem portUi config.networking.firewall.allowedTCPPorts)
               && !(lib.elem portApi config.networking.firewall.allowedTCPPorts);
      message = "open-notebook: 8555/9601 must not be open at the firewall (loopback + Pangolin only).";
    }
  ];
}
