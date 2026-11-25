# services/matrix-marc-agent/default.nix
# Minimal appservice so the hermes agent obtains, ONCE AND FOR ALL, a
# DEVICE-LINKED Matrix token on the @marc account. It is the only way to
# publish E2EE keys and therefore read/write in encrypted rooms
# (WhatsApp/Signal/Discord/Instagram/Messenger/LinkedIn bridges + encrypted DMs).
# Full context: hermes-matrix-access skill and
# /var/lib/hermes/workspace/matrix-marc/README.md (marcmsg tool that consumes
# the token produced here).
#
# Accepted side effect (validated with marc): as long as this registration is
# loaded by synapse, ALL events of the rooms where @marc is a member are
# pushed to our stub (non-exclusive users namespace, broad by construction).
# The stub only answers 200 to everything, without decrypting or logging anything:
# no payload is kept here.
{pkgs, ...}: let
  # Registration outside /var/lib/hermes: synapse (hermes group) must be able to
  # read it, but /var/lib/hermes/.matrix is 0700 (not traversable by the
  # group). StateDirectory creates the folder before the namespace: with
  # ReadWritePaths on a missing folder, the unit failed with 226/NAMESPACE.
  dataDir = "/var/lib/matrix-marc-agent-as";
  appservicePort = 29340;
  registrationFile = "${dataDir}/registration.yaml";

  tokenDir = "/var/lib/hermes/.matrix/marc-agent";
  tokenFile = "${tokenDir}/token";

  stubServer = pkgs.writeText "matrix-marc-agent-stub.py" ''
    import http.server
    import socketserver

    PORT = ${toString appservicePort}

    class Handler(http.server.BaseHTTPRequestHandler):
        def _ok(self):
            body = b"{}"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _drain(self):
            length = int(self.headers.get("Content-Length", 0) or 0)
            if length:
                self.rfile.read(length)

        def do_GET(self):
            self._ok()

        def do_PUT(self):
            self._drain()
            self._ok()

        def do_POST(self):
            self._drain()
            self._ok()

        def log_message(self, fmt, *args):
            pass

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True

    with Server(("127.0.0.1", PORT), Handler) as httpd:
        httpd.serve_forever()
  '';
in {
  systemd.services.matrix-marc-agent-as = {
    description = "HTTP appservice stub (absorbs synapse pushes for the marc-agent registration)";
    wantedBy = ["multi-user.target"];
    before = ["matrix-synapse.service"];
    preStart = ''
      if [ ! -f '${registrationFile}' ]; then
        AS_TOKEN=$(${pkgs.openssl}/bin/openssl rand -hex 32)
        HS_TOKEN=$(${pkgs.openssl}/bin/openssl rand -hex 32)
        umask 0137
        cat > '${registrationFile}' <<EOF
      id: hermes-marc-agent
      url: http://127.0.0.1:${toString appservicePort}
      as_token: $AS_TOKEN
      hs_token: $HS_TOKEN
      sender_localpart: hermes-marc-agent-bot
      rate_limited: false
      namespaces:
        users:
          - exclusive: false
            regex: '@marc:matrix\.marcpartensky\.com'
        aliases: []
        rooms: []
      EOF
        chmod 640 '${registrationFile}'
      fi
    '';
    serviceConfig = {
      Type = "simple";
      User = "hermes";
      Group = "hermes";
      ExecStart = "${pkgs.python3}/bin/python3 ${stubServer}";
      Restart = "on-failure";
      RestartSec = 10;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      StateDirectory = "matrix-marc-agent-as";
      StateDirectoryMode = "0750";
    };
  };

  # Single login (ConditionPathExists skips the step if the token already exists):
  # authenticates the appservice (m.login.application_service) to obtain an
  # access_token+device on @marc, then consumed by marcmsg.
  systemd.services.matrix-marc-agent-login = {
    description = "Appservice login -> device-linked token on @marc (only once)";
    after = ["matrix-synapse.service" "matrix-marc-agent-as.service"];
    requires = ["matrix-synapse.service"];
    wantedBy = ["multi-user.target"];
    unitConfig.ConditionPathExists = "!${tokenFile}";
    path = [pkgs.curl pkgs.yq pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "hermes";
    };
    script = ''
      set -euo pipefail
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -f '${registrationFile}' ] && break
        sleep 1
      done
      AS_TOKEN=$(yq -r '.as_token' '${registrationFile}')
      mkdir -p '${tokenDir}'
      chmod 700 '${tokenDir}'
      RESP=$(curl -sf -X POST http://127.0.0.1:8008/_matrix/client/v3/login \
        -H "Authorization: Bearer $AS_TOKEN" \
        -H 'Content-Type: application/json' \
        -d '{"type":"m.login.application_service","identifier":{"type":"m.id.user","user":"@marc:matrix.marcpartensky.com"},"device_id":"HERMESMARC01","initial_device_display_name":"hermes-agent-e2ee"}')
      TOKEN=$(printf '%s' "$RESP" | yq -r '.access_token')
      test -n "$TOKEN"
      test "$TOKEN" != "null"
      printf '%s' "$TOKEN" > '${tokenFile}'
      chmod 400 '${tokenFile}'
    '';
  };

  services.matrix-synapse.settings.app_service_config_files = [registrationFile];
  systemd.services.matrix-synapse.serviceConfig.SupplementaryGroups = ["hermes"];
  systemd.services.matrix-synapse.after = ["matrix-marc-agent-as.service"];
  systemd.services.matrix-synapse.wants = ["matrix-marc-agent-as.service"];
}
