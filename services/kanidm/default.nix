# services/kanidm/default.nix
# Kanidm - identity manager (IdM/IAM): https://github.com/kanidm/kanidm
{
  pkgs,
  config,
  lib,
  inputs,
  ...
}: let
  # public domain of the instance (to expose via pangolin/newt as auth.vps.*)
  domain = "idm.vps.marcpartensky.com";
  certs = "/var/lib/kanidm/certs";
  # kanidm_1_9 (nixos-26.05) has been EOL since 2026-05-31 -> recent version via unstable.
  # the unversioned alias pkgs.kanidm was removed from nixpkgs: explicit version required
  kanidmPkg = (import inputs.unstable {system = pkgs.stdenv.hostPlatform.system;}).kanidm_1_11;
in {
  # kanidm requires TLS even behind a reverse proxy:
  # local self-signed cert (10 years), SAN = domain + localhost
  systemd.services.kanidm-certs = {
    description = "Self-signed TLS certificate for kanidm";
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
    # if provisioning with secrets (adminPasswordFile, basicSecretFile):
    # package = kanidmPkg.withSecretProvisioning;

    server = {
      enable = true;
      settings = {
        inherit domain;
        origin = "https://${domain}";
        bindaddress = "127.0.0.1:8443"; # loopback: exposure via pangolin, no firewall port
        # ldapbindaddress = "127.0.0.1:3636"; # LDAP disabled by default
        tls_chain = "${certs}/chain.pem";
        tls_key = "${certs}/key.pem";
        online_backup.versions = 7; # daily backups (22h) in /var/lib/kanidm/backups
      };
    };

    # kanidm CLI on the machine (config in /etc/kanidm/config)
    client = {
      enable = true;
      settings = {
        uri = "https://localhost:8443";
        verify_ca = false; # self-signed cert, loopback only
      };
    };

    # unix.enable = PAM/NSS integration (login of kanidm users on the machine):
    # deliberately left disabled - a bad setup can lock out local access.

    # declarative provisioning (users/groups/OIDC clients) - uncomment and adapt:
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

  # secrets to add in secrets/tower.yml if provisioning is enabled:
  # sops.secrets."kanidm/admin_password".key = "kanidm_admin_password";
  # sops.secrets."kanidm/idm_admin_password".key = "kanidm_idm_admin_password";
  # sops.secrets."kanidm/nextcloud_secret".key = "kanidm_nextcloud_secret";
}
