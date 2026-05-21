# services/stalwart/default.nix
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
    "stalwart/mail_pw1" = {
      key = "stalwart_mail_pw1";
      owner = "stalwart-mail";
      group = "stalwart-mail";
    };
    "stalwart/mail_pw2" = {
      key = "stalwart_mail_pw2";
      owner = "stalwart-mail";
      group = "stalwart-mail";
    };
    "stalwart/admin_pw" = {
      key = "stalwart_admin_pw";
      owner = "stalwart-mail";
      group = "stalwart-mail";
    };
    "stalwart/acme_secret" = {
      key = "stalwart_acme_secret";
      owner = "stalwart-mail";
      group = "stalwart-mail";
    };
  };

  # ---------------------------------------------------------------------------
  # CONFIGURATION STALWART
  # ---------------------------------------------------------------------------
  services.stalwart-mail = {
    enable = true;
    openFirewall = true;

    # Les credentials sont passés via systemd credentials :
    # disponibles dans /run/credentials/stalwart-mail.service/<nom>
    credentials = {
      mail-pw1 = config.sops.secrets."stalwart/mail_pw1".path;
      mail-pw2 = config.sops.secrets."stalwart/mail_pw2".path;
      admin-pw = config.sops.secrets."stalwart/admin_pw".path;
      acme-secret = config.sops.secrets."stalwart/acme_secret".path;
    };

    settings = {
      server = {
        hostname = "mx1.marcpartensky.com";
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
          # JMAP + webadmin : écoute uniquement en local, Traefik fait le TLS
          jmap = {
            bind = "[::]:8390";
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
        directory = "https://acme-v02.api.letsencrypt.org/directory";
        challenge = "dns-01";
        contact = "marc@marcpartensky.com";
        domains = [
          "marcpartensky.com"
          "mx1.marcpartensky.com"
          "mail.vps.marcpartensky.com"
        ];
        provider = "cloudflare";
        # Référence le credential systemd injecté ci-dessus
        secret = "%{file:/run/credentials/stalwart-mail.service/acme-secret}%";
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
            secret = "%{file:/run/credentials/stalwart-mail.service/mail-pw1}%";
            email = ["marc@marcpartensky.com"];
          }
          {
            class = "individual";
            name = "postmaster";
            secret = "%{file:/run/credentials/stalwart-mail.service/mail-pw1}%";
            email = ["postmaster@marcpartensky.com"];
          }
          {
            class = "individual";
            name = "pro";
            secret = "%{file:/run/credentials/stalwart-mail.service/mail-pw1}%";
            email = ["pro@marcpartensky.com"];
          }
        ];
      };

      authentication.fallback-admin = {
        user = "admin";
        secret = "%{file:/run/credentials/stalwart-mail.service/admin-pw}%";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # TRAEFIK - reverse proxy pour webadmin + JMAP (remplace Caddy)
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
  #     stalwart-web.loadBalancer.servers   = [{ url = "http://127.0.0.1:8080"; }];
  #     stalwart-admin.loadBalancer.servers = [{ url = "http://127.0.0.1:8081"; }];
  #   };
  # };
}
