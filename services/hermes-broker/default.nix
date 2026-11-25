# services/hermes-broker
#
# La seule porte vers root pour l'agent Hermes. L'agent (utilisateur `hermes`)
# depose une demande sur un socket unix ; le broker, lui, tourne en root et
# n'execute rien tant qu'une preuve humaine n'est pas arrivee.
#
# Preuves acceptees, toutes armees en meme temps pour chaque demande :
#   - Touch ID natif : popup macOS sur le Mac de marc (canal par defaut, aucun
#     navigateur implique). Le broker joint le Mac par SSH et lance un helper
#     LocalAuthentication compile par Nix (packages/hermes-touch-id du flake).
#   - mot de passe systeme de marc, verifie par PAM (pamtester) : aucun secret
#     n'est stocke par le broker
#   - passkey WebAuthn, n'importe quel authentificateur : Touch ID du Mac via
#     Chrome, empreinte du telephone, Bitwarden, cle materielle. La verification
#     exige le flag de verification utilisateur, donc un geste biometrie ou PIN
#
# Les deux premiers sont natifs. La page WebAuthn reste le secours quand le Mac
# est absent (reseau, capot ferme) : elle exige un navigateur, d'ou le lien.
#
# Le canal "cle Secure Enclave signataire dans un binaire maison" reste abandonne :
# macOS exige un entitlement keychain-access-groups pour creer une cle protegee
# par biometrie, ce qui demande une identite Apple Developer (-34018 en ad-hoc).
# Le helper actuel n'a pas besoin de cle : il ne fait que rendre un code de
# sortie apres un match d'empreinte, et c'est le broker root qui le lance.
{
  config,
  lib,
  pkgs,
  ...
}: let
  python = pkgs.python3;

  # broker.py importe p256.py : les deux fichiers doivent vivre dans le meme
  # dossier, d'ou cette petite derivation plutot qu'un simple writeText.
  src = pkgs.runCommandLocal "hermes-broker-src" {} ''
    mkdir -p $out
    install -m 0644 ${./broker.py} $out/broker.py
    install -m 0644 ${./p256.py} $out/p256.py
  '';

  port = 9188;
in {
  systemd.services.hermes-broker = {
    description = "Broker d'approbation root pour Hermes (PAM + WebAuthn)";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      Type = "simple";
      User = "root";
      ExecStart = "${python}/bin/python3 ${src}/broker.py";
      WorkingDirectory = src;
      # /run/hermes-broker : le socket, proprietaire root:hermes (le broker
      # ajuste le groupe au demarrage)
      RuntimeDirectory = "hermes-broker";
      RuntimeDirectoryMode = "0750";
      # /var/lib/hermes-broker : creds.json (cles publiques) + audit.jsonl
      StateDirectory = "hermes-broker";
      StateDirectoryMode = "0700";
      Restart = "always";
      RestartSec = 2;
      # pamtester a besoin de lire /etc/shadow via PAM ; pas de durcissement
      # qui couperait l'acces au systeme d'authentification.
      PrivateTmp = true;
    };
    environment = {
      BROKER_SOCK = "/run/hermes-broker/broker.sock";
      BROKER_STATE = "/var/lib/hermes-broker";
      BROKER_PORT = toString port;
      BROKER_RP_ID = "broker.marcpartensky.com";
      BROKER_ORIGIN = "https://broker.marcpartensky.com";
      BROKER_TTL = "300";
      BROKER_PAM_USER = "marc";
      BROKER_PAMTESTER = "${pkgs.pamtester}/bin/pamtester";
      # Canal Touch ID : le broker (root) joint le Mac par SSH et lance un helper
      # du store Nix du Mac. La cle et la config sont celles de hermes, mais le
      # known_hosts est FIGE sous /etc/hermes-broker : l'agent ne peut pas le
      # reecrire pour detourner la connexion vers un faux Mac.
      BROKER_TOUCHID_SSH = "${pkgs.openssh}/bin/ssh -F /etc/hermes-broker/ssh_config mac-touchid";
      BROKER_TOUCHID_REMOTE = "/run/current-system/sw/bin/hermes-touch-id";
      BROKER_TOUCHID_TIMEOUT = "110";
    };
  };

  # Configuration SSH de root vers le Mac de marc, dediee au popup Touch ID.
  # Le known_hosts est en clair et fixe les deux cles d'hote : un saut par le VPS
  # (rack) ne suffit donc pas a usurper le Mac.
  environment.etc."hermes-broker/ssh_config".text = ''
    Host rack
      HostName marcpartensky.com
      User root
      IdentityFile /var/lib/hermes/.ssh/id_ed25519
      IdentitiesOnly yes
      BatchMode yes
      UserKnownHostsFile /etc/hermes-broker/known_hosts
      StrictHostKeyChecking yes
      ConnectTimeout 8

    Host mac-touchid
      HostName localhost
      User marc
      Port 2223
      ProxyJump rack
      IdentityFile /var/lib/hermes/.ssh/id_ed25519
      IdentitiesOnly yes
      BatchMode yes
      UserKnownHostsFile /etc/hermes-broker/known_hosts
      StrictHostKeyChecking yes
      ConnectTimeout 8
      ServerAliveInterval 15
  '';

  environment.etc."hermes-broker/known_hosts".text = ''
    marcpartensky.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMjdb63fJwF8MAsy16xVtE5fSj9Sc53n+y7P22iKkKSR
    [localhost]:2223 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID6c+5hXtBvpgtWKuC1DexczmCdKwrSqlYoa5e1qOHoB
  '';

  # Client cote agent : hermes-request --reason "..." -- cmd arg...
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "hermes-request" ''
      exec ${python}/bin/python3 ${src}/broker.py client "$@"
    '')
  ];

  # Page d'approbation publique. Pas de SSO Pangolin : c'est la page qui porte
  # l'authentification (mot de passe PAM ou assertion WebAuthn), et une
  # redirection Zitadel ferait perdre la WebAuthn (origine differente).
  services.newt.blueprint.proxy-resources.hermes-broker = {
    name = "hermes-broker";
    protocol = "http";
    full-domain = "broker.marcpartensky.com";
    auth.sso-enabled = false;
    targets = [
      {
        hostname = "127.0.0.1";
        port = port;
        method = "http";
        healthcheck = {
          enabled = true;
          hostname = "127.0.0.1";
          port = port;
          path = "/healthz";
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
}
