# services/hermes-broker
#
# The only door to root for the Hermes agent. The agent (user `hermes`)
# deposits a request on a unix socket; the broker runs as root and
# executes nothing until a human proof has arrived.
#
# Accepted proofs, all armed at the same time for each request:
#   - native Touch ID: macOS popup on marc's Mac (default channel, no
#     browser involved). The broker reaches the Mac over SSH and launches a
#     LocalAuthentication helper compiled by Nix (packages/hermes-touch-id of the flake).
#   - marc's system password, verified by PAM (pamtester): no secret
#     is stored by the broker
#   - WebAuthn passkey, any authenticator: Mac Touch ID via
#     Chrome, phone fingerprint, Bitwarden, hardware key. The verification
#     requires the user verification flag, so a biometric gesture or PIN
#
# The first two are native. The WebAuthn page remains the fallback when the Mac
# is absent (network, lid closed): it requires a browser, hence the link.
#
# The "signing Secure Enclave key in a home-made binary" channel remains abandoned:
# macOS requires a keychain-access-groups entitlement to create a key protected
# by biometrics, which needs an Apple Developer identity (-34018 in ad-hoc).
# The current helper does not need a key: it only returns an exit
# code after a fingerprint match, and it is the root broker that launches it.
{
  config,
  lib,
  pkgs,
  ...
}: let
  python = pkgs.python3;

  # broker.py imports p256.py: the two files must live in the same
  # folder, hence this small derivation rather than a simple writeText.
  src = pkgs.runCommandLocal "hermes-broker-src" {} ''
    mkdir -p $out
    install -m 0644 ${./broker.py} $out/broker.py
    install -m 0644 ${./p256.py} $out/p256.py
  '';

  port = 9188;
in {
  systemd.services.hermes-broker = {
    description = "Root approval broker for Hermes (PAM + WebAuthn)";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      Type = "simple";
      User = "root";
      ExecStart = "${python}/bin/python3 ${src}/broker.py";
      WorkingDirectory = src;
      # /run/hermes-broker: the socket, owner root:hermes (the broker
      # adjusts the group at startup)
      RuntimeDirectory = "hermes-broker";
      RuntimeDirectoryMode = "0750";
      # /var/lib/hermes-broker: creds.json (public keys) + audit.jsonl
      StateDirectory = "hermes-broker";
      StateDirectoryMode = "0700";
      Restart = "always";
      RestartSec = 2;
      # pamtester needs to read /etc/shadow via PAM; no hardening
      # that would cut access to the authentication system.
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
      # Touch ID channel: the broker (root) reaches the Mac over SSH and launches a helper
      # from the Mac's Nix store. The key and config are hermes's, but the
      # known_hosts is FROZEN under /etc/hermes-broker: the agent cannot
      # rewrite it to divert the connection to a fake Mac.
      BROKER_TOUCHID_SSH = "${pkgs.openssh}/bin/ssh -F /etc/hermes-broker/ssh_config mac-touchid";
      BROKER_TOUCHID_REMOTE = "/run/current-system/sw/bin/hermes-touch-id";
      BROKER_TOUCHID_TIMEOUT = "110";
    };
  };

  # SSH configuration of root to marc's Mac, dedicated to the Touch ID popup.
  # The known_hosts is in clear and pins the two host keys: a hop via the VPS
  # (rack) is therefore not enough to impersonate the Mac.
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

  # Client on the agent side: hermes-request --reason "..." -- cmd arg...
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "hermes-request" ''
      exec ${python}/bin/python3 ${src}/broker.py client "$@"
    '')
  ];

  # Public approval page. No Pangolin SSO: it is the page that carries
  # the authentication (PAM password or WebAuthn assertion), and a
  # Zitadel redirect would lose the WebAuthn (different origin).
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
