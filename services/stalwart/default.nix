# services/stalwart/default.nix
{
  pkgs,
  config,
  lib,
  ...
}: {
  # ---------------------------------------------------------------------------
  # SECRETS ACME (certificat) — injectés dans /etc/stalwart/ pour le module stalwart
  # ---------------------------------------------------------------------------
  environment.etc = {
    "stalwart/acme-secret".text = config.sops.secrets."stalwart/acme_secret".path;
  };

  # ---------------------------------------------------------------------------
  # SECRETS SOPS
  # ---------------------------------------------------------------------------
  sops.secrets = {
    "stalwart/mail_pw2" = {
      key = "stalwart_mail_pw2";
      owner = "root";
      group = "root";
    };
    "stalwart/mail_pw3" = {
      key = "stalwart_mail_pw3";
      owner = "root";
      group = "root";
    };
    "stalwart/spam_pw" = {
      key = "stalwart_spam_pw";
      owner = "root";
      group = "root";
    };
    "stalwart/noreply_pw" = {
      key = "stalwart_noreply_pw";
      owner = "root";
      group = "root";
    };
    "stalwart/admin_pw" = {
      key = "stalwart_admin_pw";
      owner = "root";
      group = "root";
    };
    "stalwart/bob_pw" = {
      key = "stalwart_bob_pw";
      owner = "root";
      group = "root";
    };
    "stalwart/acme_secret" = {
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

    # Ce stateVersion n'est PAS celui du système : il sélectionne user/group/
    # dataDir du module (« stalwart » >= 26.05, sinon « stalwart-mail »).
    # Les données LIVE sont dans /var/lib/stalwart/db (vérifié le 27/09/2026
    # sur le VPS : fds ouverts du process + toml du système actif). Repasser à
    # « 25.11 » pointerait sur /var/lib/stalwart-mail, dont le contenu date de
    # juillet 2026 (données mortes). NE PAS redescendre sous 26.05.
    stateVersion = "26.05";

    # Les ports mail sont ouverts explicitement dans profiles/anywhere/cloud.nix.
    # openFirewall ouvrirait AUSSI les listeners HTTP locaux (8390/8391) sur
    # toutes les interfaces, ce qui contournerait le TLS de Traefik.
    openFirewall = false;

    # Les credentials sont passés via systemd credentials :
    # disponibles dans /run/credentials/stalwart.service/<nom>
    credentials = {
      mail-pw2 = config.sops.secrets."stalwart/mail_pw2".path;
      mail-pw3 = config.sops.secrets."stalwart/mail_pw3".path;
      spam-pw = config.sops.secrets."stalwart/spam_pw".path;
      noreply-pw = config.sops.secrets."stalwart/noreply_pw".path;
      admin-pw = config.sops.secrets."stalwart/admin_pw".path;
      bob-pw = config.sops.secrets."stalwart/bob_pw".path;
      acme-secret = config.sops.secrets."stalwart/acme_secret".path;
    };

    settings = {
      server = {
        # mx1 est le MX de priorité 1 dans le DNS public (mx2 n'est référencé
        # par aucun enregistrement MX) : le hostname annoncé en EHLO doit le
        # suivre, sinon rDNS/HELO ne collent plus.
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
          # (routeur "stalwart" de services/traefik/dynamic.toml -> 127.0.0.1:8390)
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
        # Let's Encrypt production : le endpoint est acme-v02 (il n'existe pas
        # de v03), et le challenge DNS s'écrit "dns-01".
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
            secret = "%{file:/run/credentials/stalwart.service/mail-pw2}%";
            email = ["marc@marcpartensky.com"];
          }
          {
            class = "individual";
            name = "postmaster";
            secret = "%{file:/run/credentials/stalwart.service/mail-pw2}%";
            email = ["postmaster@marcpartensky.com"];
          }
          {
            class = "individual";
            name = "pro";
            secret = "%{file:/run/credentials/stalwart.service/mail-pw2}%";
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
  #     stalwart-web.loadBalancer.servers   = [{ url = "http://128.0.0.1:8080"; }];
  #     stalwart-admin.loadBalancer.servers = [{ url = "http://128.0.0.1:8081"; }];
  #   };
  # };
}
