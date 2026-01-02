{ config, pkgs, ... }:

{
  # 1. Gestion des secrets (Minimaliste)
  # Note: En production, privilégiez sops-nix ou agenix.
  environment.etc = {
    "stalwart/mail-pw1".text = "motdepasse_utilisateur";
    "stalwart/admin-pw".text = "motdepasse_admin";
    "stalwart/acme-secret".text = "votre_cle_api_dns_cloudflare"; # Si challenge dns-01
  };

   # Configuration de sops
  sops = {
    defaultSopsFile = ./secrets/anywhere.yml;
    # age.keyFile = "/var/lib/sops-nix/key.txt";
    
    # Définition des secrets
    secrets = {
      "stalwart/mail-pw1" = {
        owner = "stalwart-mail";
        group = "stalwart-mail";
        mode = "0400";
      };
      "stalwart/admin-pw" = {
        owner = "stalwart-mail";
        group = "stalwart-mail";
        mode = "0400";
      };
      "stalwart/acme-secret" = {
        owner = "stalwart-mail";
        group = "stalwart-mail";
        mode = "0400";
      };
    };
  };

  # 2. Service Stalwart Mail
  services.stalwart-mail = {
    enable = true;
    openFirewall = true;
    settings = {
      server = {
        tracer.stdout = {
          level = "debug"; # Changez "info" en "debug"
          type = "stdout";
        };
        hostname = "mx1.marcpartensky.com";
        tls = {
          enable = true;
          implicit = true;
        };
        listener = {
          smtp = {
            protocol = "smtp";
            bind = "[::]:25";
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
          management = {
            # bind = [ "127.0.0.1:8090" ];
            bind = [ "0.0.0.0:8090" ];
            protocol = "http";
            url = "https://mail.vps.marcpartensky.com";
          };
        };
      };

      lookup.default = {
        hostname = "mx1.marcpartensky.com";
        domain = "marcpartensky.com";
      };

      # Configuration ACME via Stalwart (interne)
      acme."letsencrypt" = {
        directory = "https://acme-v02.api.letsencrypt.org/directory";
        challenge = "dns-01";
        contact = "admin@marcpartensky.com";
        domains = [ "marcpartensky.com" "mx1.marcpartensky.com" "mail.vps.marcpartensky.com" ];
        provider = "cloudflare"; # Assurez-vous d'utiliser le bon provider
        secret = "%{file:/etc/stalwart/acme-secret}%";
      };

      # Attention: 'in-memory' efface tout au redémarrage !
      # Pour un usage réel, utilisez "rocksdb" ou "sqlite"
      storage.directory = "rocksdb"; 
      
      directory."in-memory" = {
        type = "memory";
        principals = [
          {
            class = "individual";
            name = "Marc";
            secret = "%{file:/etc/stalwart/mail-pw1}%";
            email = [ "marc@marcpartensky.com" ];
          }
        ];
      };

      authentication.fallback-admin = {
        user = "admin";
        secret = "%{file:/etc/stalwart/admin-pw}%";
      };
    };
  };

  # 3. Reverse Proxy Caddy pour l'interface Web
  # services.caddy = {
  #   enable = true;
  #   virtualHosts = {
  #     "mail.marcpartensky.com" = {
  #       extraConfig = ''
  #         reverse_proxy 127.0.0.1:8080
  #       '';
  #     };
  #   };
  # };
}
