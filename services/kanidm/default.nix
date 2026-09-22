# services/kanidm/default.nix
# Kanidm — gestionnaire d'identité (IdM/IAM) : https://github.com/kanidm/kanidm
{
  pkgs,
  config,
  lib,
  inputs,
  ...
}: let
  # domaine public de l'instance (à exposer via pangolin/newt comme auth.vps.*)
  domain = "idm.vps.marcpartensky.com";
  certs = "/var/lib/kanidm/certs";
  # kanidm_1_9 (nixos-26.05) est EOL depuis 2026-05-31 → version récente via unstable.
  # l'alias non versionné pkgs.kanidm a été retiré de nixpkgs : version explicite obligatoire
  kanidmPkg = (import inputs.unstable {system = pkgs.stdenv.hostPlatform.system;}).kanidm_1_11;
in {
  # kanidm exige du TLS même derrière un reverse proxy :
  # cert auto-signé local (10 ans), SAN = domaine + localhost
  systemd.services.kanidm-certs = {
    description = "Certificat TLS auto-signé pour kanidm";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "kanidm";
    };
    script = ''
      mkdir -p ${certs}
      if [ ! -s ${certs}/key.pem ]; then
        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
          -subj "/CN=${domain}" \
          -addext "subjectAltName=DNS:${domain},DNS:localhost,IP:127.0.0.1" \
          -keyout ${certs}/key.pem -out ${certs}/chain.pem
        chmod 600 ${certs}/key.pem
      fi
      chown -R kanidm:kanidm ${certs}
    '';
  };

  systemd.services.kanidm = {
    requires = ["kanidm-certs.service"];
    after = ["kanidm-certs.service"];
  };

  services.kanidm = {
    package = kanidmPkg;
    # si provision avec secrets (adminPasswordFile, basicSecretFile) :
    # package = kanidmPkg.withSecretProvisioning;

    server = {
      enable = true;
      settings = {
        inherit domain;
        origin = "https://${domain}";
        bindaddress = "127.0.0.1:8443"; # loopback : exposition via pangolin, pas de port pare-feu
        # ldapbindaddress = "127.0.0.1:3636"; # LDAP désactivé par défaut
        tls_chain = "${certs}/chain.pem";
        tls_key = "${certs}/key.pem";
        online_backup.versions = 7; # backups quotidiens (22h) dans /var/lib/kanidm/backups
      };
    };

    # CLI kanidm sur la machine (config dans /etc/kanidm/config)
    client = {
      enable = true;
      settings = {
        uri = "https://localhost:8443";
        verify_ca = false; # cert auto-signé, loopback uniquement
      };
    };

    # unix.enable = intégration PAM/NSS (login des users kanidm sur la machine) :
    # laissé désactivé volontairement — un mauvais setup peut verrouiller l'accès local.

    # provisioning déclaratif (users/groupes/clients OIDC) — décommenter et adapter :
    # provision = {
    #   enable = true;
    #   adminPasswordFile = config.sops.secrets."kanidm/admin_password".path;
    #   idmAdminPasswordFile = config.sops.secrets."kanidm/idm_admin_password".path;
    #   persons.marc = {
    #     displayName = "Marc";
    #     mailAddresses = ["marc@marcpartensky.com"];
    #     groups = ["nextcloud_users"];
    #   };
    #   groups.nextcloud_users = {};
    #   systems.oauth2.nextcloud = {
    #     displayName = "Nextcloud";
    #     originUrl = "https://cloud.vps.marcpartensky.com/apps/user_oidc/code";
    #     originLanding = "https://cloud.vps.marcpartensky.com";
    #     basicSecretFile = config.sops.secrets."kanidm/nextcloud_secret".path;
    #     scopeMaps.nextcloud_users = ["openid" "profile" "email"];
    #   };
    # };
  };

  # secrets à ajouter dans secrets/tower.yml si provision activée :
  # sops.secrets."kanidm/admin_password".key = "kanidm_admin_password";
  # sops.secrets."kanidm/idm_admin_password".key = "kanidm_idm_admin_password";
  # sops.secrets."kanidm/nextcloud_secret".key = "kanidm_nextcloud_secret";
}
