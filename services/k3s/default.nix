{
  lib,
  pkgs,
  ...
}: let
  # Rancher is reached by newt (which runs on tower) via a FIXED service IP,
  # in the k3s services CIDR (10.43.0.0/16). Point: Rancher's port
  # is not open on ANY interface (neither LAN nor loopback), and
  # the address does not move on cluster restart, so the Pangolin target
  # can stay declarative. 10.43.0.10 is taken by coredns, we take .99.10.
  rancherClusterIP = "10.43.99.10";

  # Second fixed point, in front of the first: an nginx that injects the
  # Catppuccin theme. The Rancher dashboard is a SPA whose whole palette comes from
  # CSS variables (cf. catppuccin-mocha-rancher.css): without this hop, the theme
  # would require patching the container image. Switching = replacing
  # rancherClusterIP with rancherThemeClusterIP in the Pangolin resource
  # below (one line), the /healthz healthcheck stays valid (it goes through).
  rancherThemeClusterIP = "10.43.99.11";

  # Rancher (the chart, its control-plane pods and its Pangolin resource)
  # is DISABLED since 20/11/2026: measurement of 1.5 cores continuously for
  # 10 pods that served no workload (rancher, fleet, capi, turtles,
  # webhook, gitjob) and a kine datastore that failed to compact every
  # 5 min. k3s itself stays active: it is what provides the pods API.
  # Setting this flag back to true restores the chart and the exposure resource, without
  # touching the rest of the module.
  withRancher = false;
in {
  # single-node k3s on tower, dedicated to the Rancher console.
  #
  # Scope:
  #   - keeps coredns (internal DNS) + flannel (vxlan) + kube-proxy
  #   - cuts: traefik, servicelb, local-storage, metrics-server
  #     (no ingress in the cluster: TLS is terminated by Pangolin on the
  #     VPS side, Rancher receives plain HTTP on its port 80)
  #   - Rancher 2.15.3 installed by the helm-controller built into k3s, chart
  #     pinned version + hash (nothing is pulled at boot)
  #   - MemoryMax 6G on k3s.service: Rancher, fleet and the webhook live
  #     in this cgroup. Safeguard; measurement of 14/11: ~0.6 GB idle without
  #     workload, ~578 MiB with coredns alone.
  #   - kubeconfig in 0644 so the agent can drive the cluster without sudo
  #
  # Exposure: Pangolin resource declared here (this module is only imported
  # by tower), target 10.43.99.10:80, Zitadel SSO on the edge side.
  #
  # Full deactivation: comment out the import in
  # profiles/tower/configuration.nix, rebuild, then delete
  # /var/lib/rancher/k3s and /etc/rancher/k3s (root).
  #
  # Debug: kubectl (kubeconfig already in place), cost read from
  # /sys/fs/cgroup/system.slice/k3s.service/{memory.current,cpu.stat}.

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--disable=traefik"
      "--disable=servicelb"
      "--disable=local-storage"
      "--disable=metrics-server"
      "--write-kubeconfig-mode=0644"
    ];

    autoDeployCharts.rancher = lib.mkIf withRancher {
      name = "rancher";
      repo = "https://releases.rancher.com/server-charts/stable";
      version = "2.15.3";
      hash = "sha256-NDiIxmQhqfVma1Ys3+ynUdY9qZTtvnsbNnUvj/z17NQ=";
      targetNamespace = "cattle-system";
      createNamespace = true;

      values = {
        hostname = "rancher.marcpartensky.com";
        replicas = 1;

        # TLS terminated upstream (Pangolin): Rancher serves plain HTTP on 80,
        # without cert-manager or Ingress in the cluster.
        tls = "external";
        networkExposure.type = "none";
        ingress.enabled = false;
        service.type = "ClusterIP";

        # Without an Ingress, Rancher cannot guess its public URL: it is
        # the only thing the chart does not derive itself.
        extraEnv = [
          {
            name = "CATTLE_SERVER_URL";
            value = "https://rancher.marcpartensky.com";
          }
        ];

        resources = {
          requests = {
            cpu = "100m";
            memory = "512Mi";
          };
          limits.memory = "2Gi";
        };
      };

      # Fixed-IP Service in front of the Rancher pod: the chart's Service gets
      # a dynamically allocated IP, unusable as a declarative target.
      extraDeploy = [
        {
          apiVersion = "v1";
          kind = "Service";
          metadata = {
            name = "rancher-fixed";
            namespace = "cattle-system";
          };
          spec = {
            type = "ClusterIP";
            clusterIP = rancherClusterIP;
            selector.app = "rancher";
            ports = [
              {
                name = "http";
                port = 80;
                targetPort = 80;
                protocol = "TCP";
              }
            ];
          };
        }

        # ----------------------------------------------------------------
        # Catppuccin theme: nginx in front of Rancher, which injects a stylesheet
        # into the dashboard HTML. No custom image, no Rancher file
        # touched: both files come from the ConfigMap.
        # ----------------------------------------------------------------
        {
          apiVersion = "v1";
          kind = "ConfigMap";
          metadata = {
            name = "rancher-theme";
            namespace = "cattle-system";
          };
          data = {
            "default.conf" = ''
              map $http_upgrade $connection_upgrade {
                default upgrade;
                "" close;
              }

              server {
                listen 80;
                server_name _;

                # Catppuccin stylesheet served by this proxy, not by Rancher.
                location = /__catppuccin.css {
                  default_type text/css;
                  alias /usr/share/nginx/theme/catppuccin.css;
                  add_header Cache-Control "max-age=600";
                }

                location / {
                  proxy_pass http://rancher-fixed.cattle-system.svc.cluster.local:80;
                  proxy_http_version 1.1;
                  # Real Host (rancher.marcpartensky.com): Rancher builds
                  # its absolute URLs on it, and the dashboard's kubectl shell
                  # goes over WebSocket, hence Upgrade/Connection.
                  proxy_set_header Host $http_host;
                  proxy_set_header X-Forwarded-Proto https;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header Upgrade $http_upgrade;
                  proxy_set_header Connection $connection_upgrade;
                  # sub_filter replaces nothing on a compressed stream.
                  proxy_set_header Accept-Encoding "";
                  proxy_read_timeout 3600s;
                  proxy_send_timeout 3600s;
                  proxy_buffering off;
                  sub_filter_types text/html;
                  sub_filter_once on;
                  sub_filter '</head>' '<link rel="stylesheet" href="/__catppuccin.css"></head>';
                }
              }
            '';
            # Theme copy: a single source file, in this folder.
            "catppuccin.css" = builtins.readFile ./catppuccin-mocha-rancher.css;
          };
        }

        {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata = {
            name = "rancher-theme";
            namespace = "cattle-system";
            labels.app = "rancher-theme";
          };
          spec = {
            replicas = 1;
            selector.matchLabels.app = "rancher-theme";
            template = {
              metadata.labels.app = "rancher-theme";
              spec = {
                containers = [
                  {
                    name = "nginx";
                    image = "docker.io/library/nginx:1.29-alpine";
                    ports = [ { containerPort = 80; } ];
                    resources = {
                      requests = {
                        cpu = "10m";
                        memory = "16Mi";
                      };
                      limits.memory = "64Mi";
                    };
                    # /healthz goes through the proxy up to Rancher: the probe
                    # proves end to end, not only nginx.
                    readinessProbe = {
                      httpGet = {
                        path = "/healthz";
                        port = 80;
                      };
                      initialDelaySeconds = 5;
                      periodSeconds = 10;
                    };
                    livenessProbe = {
                      httpGet = {
                        path = "/healthz";
                        port = 80;
                      };
                      initialDelaySeconds = 20;
                      periodSeconds = 30;
                    };
                    volumeMounts = [
                      {
                        name = "conf";
                        mountPath = "/etc/nginx/conf.d/default.conf";
                        subPath = "default.conf";
                      }
                      {
                        name = "theme";
                        mountPath = "/usr/share/nginx/theme/catppuccin.css";
                        subPath = "catppuccin.css";
                      }
                    ];
                  }
                ];
                volumes = [
                  {
                    name = "conf";
                    configMap.name = "rancher-theme";
                  }
                  {
                    name = "theme";
                    configMap.name = "rancher-theme";
                  }
                ];
              };
            };
          };
        }

        {
          apiVersion = "v1";
          kind = "Service";
          metadata = {
            name = "rancher-themed";
            namespace = "cattle-system";
          };
          spec = {
            type = "ClusterIP";
            clusterIP = rancherThemeClusterIP;
            selector.app = "rancher-theme";
            ports = [
              {
                name = "http";
                port = 80;
                targetPort = 80;
                protocol = "TCP";
              }
            ];
          };
        }
      ];
    };
  };

  # Public Pangolin resource: the edge terminates TLS (wildcard certificate
  # of the VPS) and applies the Zitadel SSO, then pushes HTTP to the target.
  # `site` is omitted: Pangolin assigns the site that applies the blueprint.
  services.newt.blueprint.proxy-resources.rancher = lib.mkIf withRancher {
    name = "rancher";
    protocol = "http";
    full-domain = "rancher.marcpartensky.com";
    auth.sso-enabled = true;
    targets = [
      {
        # Useful healthcheck: it is the only automatic proof that the tunnel
        # really reaches Rancher, and it avoids the 503 "no available server"
        # when the pod restarts. /healthz answers 200 without the
        # X-Forwarded-Proto header (verified), whereas "/" returns a 302 to https.
        healthcheck = {
          enabled = true;
          hostname = rancherClusterIP;
          port = 80;
          path = "/healthz";
          method = "GET";
          mode = "http";
          scheme = "http";
          interval = 30;
          unhealthy-interval = 30;
          timeout = 5;
          healthy-threshold = 1;
          unhealthy-threshold = 3;
        };
        hostname = rancherClusterIP;
        port = 80;
        method = "http";
      }
    ];
  };

  # The NixOS nftables firewall cuts incoming traffic on the CNI
  # interfaces: without it, coredns and the pods receive nothing.
  networking.firewall.trustedInterfaces = [ "cni0" "flannel.1" ];

  # kubectl for the agent (it does not have marc's home-manager).
  environment.systemPackages = [ pkgs.kubectl ];

  systemd.services.k3s.serviceConfig = {
    Nice = 10;
    CPUWeight = 50;
    MemoryMax = "6G";
  };
}
