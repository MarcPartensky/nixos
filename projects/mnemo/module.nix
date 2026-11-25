# NixOS module for mnemo, exported as `nixosModules.default`.
#
# The system flake consumes it from a copy vendored at projects/mnemo:
#
#   inputs.mnemo = { url = "path:./projects/mnemo"; inputs.nixpkgs.follows = "nixpkgs"; };
#
#   imports = [ inputs.mnemo.nixosModules.default ];
#   services.mnemo.enable = true;
#
# Shape of the deployment, and why:
#
#   - The engine runs as a POD in the k3s cluster that already lives on tower.
#     The manifest is declared through `services.k3s.manifests`, so k3s applies
#     it itself: no helm, no kubectl apply, no drift. The manifest is written as
#     Nix data, not as a YAML string, so a typo is a build error.
#   - The pod uses `hostNetwork`. Postgres stays on the host with its loopback
#     trust rule, and Pangolin's target stays `127.0.0.1:<port>` like every
#     other service of this host. No pg_hba change, no ClusterIP hop.
#   - The image is built on the LAPTOP (`nix build .#image` in the repo) and
#     shipped as a tarball: nothing compiles Rust on tower, whose CPU belongs to
#     Marc. This module only imports the tarball into containerd.
#   - This module never references a Rust derivation. That is deliberate: a
#     `services.mnemo.package` in `environment.systemPackages` would make a
#     tower rebuild compile the binary. The CLI runs from the laptop, or inside
#     the pod.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.mnemo;

  schema = pkgs.writeText "mnemo-schema.sql" (builtins.readFile ./sql/schema.sql);

  env = name: value: {inherit name value;};

  # The pod, as data. k3s links it into /var/lib/rancher/k3s/server/manifests
  # and applies it, including on change.
  pod = [
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = cfg.namespace;
    }
    {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {
        name = "mnemo";
        namespace = cfg.namespace;
        labels.app = "mnemo";
      };
      spec = {
        replicas = 1;
        strategy.type = "Recreate";
        selector.matchLabels.app = "mnemo";
        template = {
          metadata.labels.app = "mnemo";
          spec = {
            hostNetwork = true;
            dnsPolicy = "ClusterFirstWithHostNet";
            securityContext = {
              runAsUser = cfg.uid;
              runAsGroup = cfg.gid;
              runAsNonRoot = true;
            };
            containers = [
              {
                name = "mnemo";
                image = cfg.imageName;
                imagePullPolicy = "Never";
                args = ["serve"];
                ports = [
                  {
                    name = "http";
                    containerPort = cfg.port;
                    hostPort = cfg.port;
                  }
                ];
                env = [
                  (env "HOME" "/data")
                  # Loopback only: hostNetwork means this is the host loopback,
                  # so Pangolin's target works, and the pod is not reachable from
                  # the tailnet. Do NOT lean on the firewall to close the port:
                  # tailscale0 is a trusted interface.
                  (env "MNEMO_BIND" "127.0.0.1")
                  (env "MNEMO_PORT" (toString cfg.port))
                  # Pangolin terminates the login: the app trusts the edge and
                  # the port is loopback, so a second token in the browser would
                  # only break the page.
                  (env "MNEMO_OPEN" "1")
                  (env "MNEMO_DB" "postgres://${cfg.dbUser}@127.0.0.1:5432/${cfg.database}")
                  (env "MNEMO_SESSIONS_DB" "/data/state.db")
                  (env "MNEMO_TOKEN_FILE" "${cfg.stateDir}/mnemo-token")
                  (env "MNEMO_BRIEF_DIR" "${cfg.stateDir}/briefs")
                  (env "MNEMO_TYPER_DIR" "${cfg.stateDir}/typer-lang")
                  (env "MNEMO_HUB_URL" cfg.hubUrl)
                  (env "MNEMO_HUB_TOKEN_FILE" "/data/podcast-hub-token")
                  (env "MNEMO_LLM_URL" cfg.llmUrl)
                  (env "MNEMO_LLM_MODEL" cfg.llmModel)
                  (env "MNEMO_MIN_PRIORITY" (toString cfg.minPriority))
                  (env "MNEMO_BATCH" "5")
                  # Generous on purpose: a reasoning model spends most of the
                  # budget on its scratchpad before writing anything, and a
                  # tight limit returns a truncated answer that looks fine.
                  (env "MNEMO_ANALYZE_TOKENS" "8000")
                  (env "MNEMO_BRIEF_TOKENS" "6000")
                ];
                volumeMounts = [
                  {
                    name = "hermes";
                    mountPath = "/data";
                    readOnly = true;
                  }
                  {
                    name = "state";
                    mountPath = cfg.stateDir;
                  }
                ];
                resources = {
                  requests = {
                    cpu = "50m";
                    memory = "96Mi";
                  };
                  limits = {
                    cpu = "1";
                    memory = "512Mi";
                  };
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = ["ALL"];
                };
                readinessProbe = {
                  httpGet = {
                    path = "/healthz";
                    port = cfg.port;
                    # Required: with hostNetwork the kubelet probes the pod IP
                    # (the node IP) unless told otherwise, and a loopback-bound
                    # server refuses that, so the pod would never go Ready.
                    host = "127.0.0.1";
                  };
                  initialDelaySeconds = 3;
                  periodSeconds = 15;
                };
                livenessProbe = {
                  httpGet = {
                    path = "/healthz";
                    port = cfg.port;
                    host = "127.0.0.1";
                  };
                  initialDelaySeconds = 10;
                  periodSeconds = 60;
                };
              }
            ];
            volumes = [
              {
                name = "hermes";
                hostPath = {
                  path = cfg.hermesHome;
                  type = "Directory";
                };
              }
              {
                name = "state";
                hostPath = {
                  path = cfg.stateDir;
                  type = "Directory";
                };
              }
            ];
          };
        };
      };
    }
  ];
in {
  options.services.mnemo = {
    enable = lib.mkEnableOption "mnemo (retention engine: scores, gaps, briefs, podcast sources)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9152;
      description = "Loopback port the pod binds (hostNetwork), the target Pangolin points at.";
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "mnemo";
      description = "Kubernetes namespace of the deployment.";
    };

    imageName = lib.mkOption {
      type = lib.types.str;
      default = "mnemo:0.1.0";
      description = "Image tag inside the cluster; must match the built tarball.";
    };

    imageFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hermes/mnemo/mnemo-oci.tar";
      description = ''
        OCI tarball built on the laptop with `nix build .#image` and copied to
        the host. Imported into containerd at activation when it is present.
        The default sits under the agent's home because that is where the agent
        can drop it without root; root only reads it.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/mnemo";
      description = "Host directory the pod writes to (token, briefs, typing list).";
    };

    hermesHome = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/hermes/.hermes";
      description = "Hermes home, mounted read-only: the sessions database is read there.";
    };

    database = lib.mkOption {
      type = lib.types.str;
      default = "mnemo";
      description = "Postgres database created for the service.";
    };

    dbUser = lib.mkOption {
      type = lib.types.str;
      default = "mnemo";
      description = "Postgres role owning that database.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 988;
      description = "uid the pod runs as; must own stateDir and be able to read hermesHome.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 982;
      description = "gid the pod runs as.";
    };

    llmUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://100.64.0.4:8094/v1";
      description = "OpenAI-compatible endpoint used for scoring and writing. Default is the free pool on the laptop.";
    };

    llmModel = lib.mkOption {
      type = lib.types.str;
      default = "free-pool";
      description = "Model alias sent to that endpoint.";
    };

    hubUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8095";
      description = "Podcast hub. mnemo enqueues into it instead of generating episodes itself.";
    };

    minPriority = lib.mkOption {
      type = lib.types.float;
      default = 8.0;
      description = "Below this priority a conversation is scored but gets no brief.";
    };
  };

  config = lib.mkIf cfg.enable {
    # One role and one database per service: nothing shared, nothing to guess.
    services.postgresql.ensureDatabases = [cfg.database];
    services.postgresql.ensureUsers = [
      {
        name = cfg.dbUser;
        ensureDBOwnership = true;
      }
    ];

    # Idempotent: the schema is `create table if not exists` everywhere. Ordered
    # after postgresql-setup, which is the unit that creates the role and the
    # database: `after postgresql.service` alone would race with it on the very
    # switch that creates them.
    systemd.services.mnemo-schema = {
      description = "mnemo: apply the database schema";
      wantedBy = ["multi-user.target"];
      after = ["postgresql-setup.service"];
      requires = ["postgresql-setup.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
      };
      script = ''
        ${config.services.postgresql.package}/bin/psql \
          --no-psqlrc --set ON_ERROR_STOP=1 -d ${cfg.database} -f ${schema}
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${toString cfg.uid} ${toString cfg.gid} -"
      "d ${cfg.stateDir}/briefs 0750 ${toString cfg.uid} ${toString cfg.gid} -"
      "d ${cfg.stateDir}/typer-lang 0750 ${toString cfg.uid} ${toString cfg.gid} -"
    ];

    # The image arrives as a file; containerd learns it at activation.
    systemd.services.mnemo-image = {
      description = "mnemo: import the OCI image into containerd";
      wantedBy = ["multi-user.target"];
      after = ["k3s.service"];
      requires = ["k3s.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ -f ${cfg.imageFile} ]; then
          ${config.services.k3s.package}/bin/k3s ctr images import ${cfg.imageFile}
        else
          echo "mnemo: ${cfg.imageFile} absent, build it on the laptop: nix build .#image" >&2
        fi
      '';
    };

    # k3s applies everything under its manifest directory, and re-applies on
    # change. Declaring it here means the pod exists because the config says so.
    services.k3s.manifests.mnemo = lib.mkIf (config.services.k3s.enable or false) {
      target = "mnemo.yaml";
      content = pod;
    };
  };
}
