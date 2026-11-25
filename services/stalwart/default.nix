# services/stalwart/default.nix
{
  pkgs,
  config,
  lib,
  ...
}: {
  # ---------------------------------------------------------------------------
  # ACME SECRETS (certificate) - injected into /etc/stalwart/ for the stalwart module
  # ---------------------------------------------------------------------------
  environment.etc = {
    "stalwart/acme-secret".text = config.sops.secrets."stalwart/acme".path;
  };

  # ---------------------------------------------------------------------------
  # SECRETS SOPS
  # ---------------------------------------------------------------------------
  sops.secrets = {
    "stalwart/mail" = {
      key = "stalwart_mail_password";
      owner = "root";
      group = "root";
    };
    "stalwart/spam" = {
      key = "stalwart_spam_password";
      owner = "root";
      group = "root";
    };
    "stalwart/noreply" = {
      key = "stalwart_noreply_password";
      owner = "root";
      group = "root";
    };
    "stalwart/admin" = {
      key = "stalwart_admin_password";
      owner = "root";
      group = "root";
    };
    "stalwart/bob" = {
      key = "stalwart_bob_password";
      owner = "root";
      group = "root";
    };
    "stalwart/acme" = {
      key = "stalwart_acme_secret";
      owner = "root";
      group = "root";
    };
  };

  # ---------------------------------------------------------------------------
  # CONFIGURATION STALWART
  # ---------------------------------------------------------------------------
  services.stalwart = {
    enable = true;

    # This stateVersion is NOT the system one: it selects user/group/
    # dataDir of the module ("stalwart" >= 26.05, otherwise "stalwart-mail").
    # The LIVE data is in /var/lib/stalwart/db (verified on 27/09/2026
    # on the VPS: open fds of the process + toml of the active system). Going back to
    # "25.11" would point to /var/lib/stalwart-mail, whose content dates from
    # July 2026 (dead data). Do NOT go back below 26.05.
    stateVersion = "26.05";

    # The mail ports are opened explicitly in profiles/anywhere/cloud.nix.
    # openFirewall would ALSO open the local HTTP listeners (8390/8391) on
    # all interfaces, which would bypass Traefik's TLS.
    openFirewall = false;

    # The credentials are passed via systemd credentials:
    # available in /run/credentials/stalwart.service/<name>
    credentials = {
      mail-pw = config.sops.secrets."stalwart/mail".path;
      spam-pw = config.sops.secrets."stalwart/spam".path;
      noreply-pw = config.sops.secrets."stalwart/noreply".path;
      admin-pw = config.sops.secrets."stalwart/admin".path;
      bob-pw = config.sops.secrets."stalwart/bob".path;
      acme-secret = config.sops.secrets."stalwart/acme".path;
    };

    settings = {
      server = {
        # mx1 is the priority-1 MX in the public DNS (mx2 is not referenced
        # by any MX record): the hostname announced in EHLO must
        # follow it, otherwise rDNS/HELO no longer match.
        hostname = "mx1.marcpartensky.com";

        # Stalwart's auto-ban (server.auto-ban.auth/scan/loiter, active by
        # default) writes each banned IP into ITS config DB, so the ban survives
        # restarts: a home IP can stay blocked on 25/465/993
        # (connection accepted then reset, log "Blocked IP address") until a
        # manual unblock. We therefore explicitly allow marc's home:
        # allowed-ip bypasses the auto-ban (127.0.0.1/::1 already are by default).
        # If the public IP changes, update this entry.
        allowed-ip = {
          "66.108.44.154" = "";
        };

        tls = {
          enable = true;
          implicit = true;
        };
        listener = {
          smtp = {
            bind = "[::]:25";
            protocol = "smtp";
          };
          submissions = {
            bind = "[::]:465";
            protocol = "smtp";
            tls.implicit = true;
          };
          imaps = {
            bind = "[::]:993";
            protocol = "imap";
            tls.implicit = true;
          };
          # JMAP + webadmin: listens only locally, Traefik does the TLS
          # ("stalwart" router of services/traefik/dynamic.toml -> 127.0.0.1:8390)
          jmap = {
            bind = "127.0.0.1:8390";
            url = "https://mail.vps.marcpartensky.com";
            protocol = "http";
          };
          management = {
            bind = ["127.0.0.1:8391"];
            protocol = "http";
          };
        };
      };

      lookup.default = {
        hostname = "mx1.marcpartensky.com";
        domain = "marcpartensky.com";
      };

      acme."letsencrypt" = {
        # Let's Encrypt production: the endpoint is acme-v02 (there is no
        # v03), and the DNS challenge is written "dns-01".
        directory = "https://acme-v02.api.letsencrypt.org/directory";
        challenge = "dns-01";
        contact = "marc@marcpartensky.com";
        domains = [
          "marcpartensky.com"
          "mx1.marcpartensky.com"
          "mail.vps.marcpartensky.com"
        ];
        provider = "cloudflare";
        # References the systemd credential injected above
        secret = "%{file:/etc/stalwart/acme-secret}%";
      };

      session.auth = {
        mechanisms = "[plain]";
        directory = "'in-memory'";
      };

      storage.directory = "in-memory";
      session.rcpt.directory = "'in-memory'";

      directory."imap".lookup.domains = ["marcpartensky.com"];

      directory."in-memory" = {
        type = "memory";
        principals = [
          {
            class = "individual";
            name = "marc";
            secret = "%{file:/run/credentials/stalwart.service/mail-pw}%";
            email = [
              "marc@marcpartensky.com"
              "meetup@marcpartensky.com"
            ];
          }
          {
            class = "individual";
            name = "postmaster";
            secret = "%{file:/run/credentials/stalwart.service/mail-pw}%";
            email = ["postmaster@marcpartensky.com"];
          }
          {
            class = "individual";
            name = "pro";
            secret = "%{file:/run/credentials/stalwart.service/mail-pw}%";
            email = ["pro@marcpartensky.com"];
          }
          {
            class = "individual";
            name = "spam";
            secret = "%{file:/run/credentials/stalwart.service/spam-pw}%";
            email = ["spam@marcpartensky.com"];
          }
          {
            class = "individual";
            name = "noreply";
            secret = "%{file:/run/credentials/stalwart.service/noreply-pw}%";
            email = ["noreply@marcpartensky.com"];
          }
          {
            class = "individual";
            name = "bob";
            secret = "%{file:/run/credentials/stalwart.service/bob-pw}%";
            email = ["bob@marcpartensky.com"];
          }
        ];
      };

      authentication.fallback-admin = {
        user = "admin";
        secret = "%{file:/run/credentials/stalwart.service/admin-pw}%";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # TRAEFIK - reverse proxy for webadmin + JMAP (replaces Caddy)
  # ---------------------------------------------------------------------------
  # services.traefik.dynamicConfigOptions.http = {
  #   routers = {
  #     stalwart-web = {
  #       rule = "Host(`mail.marcpartensky.com`) || Host(`mta-sts.marcpartensky.com`) || Host(`autoconfig.marcpartensky.com`) || Host(`autodiscover.marcpartensky.com`)";
  #       entryPoints = [ "websecure" ];
  #       service = "stalwart-web";
  #       tls.certResolver = "letsencrypt";
  #     };
  #     stalwart-admin = {
  #       rule = "Host(`webmail.vps.marcpartensky.com`)";
  #       entryPoints = [ "websecure" ];
  #       service = "stalwart-admin";
  #       tls.certResolver = "letsencrypt";
  #     };
  #   };
  #   services = {
  #     stalwart-web.loadBalancer.servers   = [{ url = "http://128.0.0.1:8080"; }];
  #     stalwart-admin.loadBalancer.servers = [{ url = "http://128.0.0.1:8081"; }];
  #   };
  # };
}
