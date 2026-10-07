# services/matrix-marc-agent/default.nix
# Appservice minimal pour que l'agent hermes obtienne, UNE SEULE FOIS, un token
# Matrix LIE A UN APPAREIL sur le compte de @marc. C'est le seul moyen de
# publier des cles E2EE et donc de lire/ecrire dans les salons chiffres
# (ponts WhatsApp/Signal/Discord/Instagram/Messenger/LinkedIn + DM chiffres).
# Contexte complet : skill hermes-matrix-access et
# /var/lib/hermes/workspace/matrix-marc/README.md (outil marcmsg qui consomme
# le token produit ici).
#
# Effet de bord assume (valide avec marc) : tant que cette registration est
# chargee par synapse, TOUS les evenements des salons ou @marc est membre sont
# pousses vers notre stub (namespace users non exclusif, large par construction).
# Le stub ne fait que repondre 200 a tout, sans rien dechiffrer ni journaliser :
# aucune charge utile n'est conservee ici.
{pkgs, ...}: let
  # Registration hors de /var/lib/hermes : synapse (groupe hermes) doit pouvoir
  # la lire, or /var/lib/hermes/.matrix est en 0700 (non traversable par le
  # groupe). StateDirectory cree le dossier avant le namespace : avec
  # ReadWritePaths sur un dossier absent, l'unite echouait en 226/NAMESPACE.
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
    description = "Stub appservice HTTP (encaisse les pushs synapse pour la registration marc-agent)";
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

  # Login unique (ConditionPathExists saute l'etape si le token existe deja) :
  # authentifie l'appservice (m.login.application_service) pour obtenir un
  # access_token+device sur @marc, consomme ensuite par marcmsg.
  systemd.services.matrix-marc-agent-login = {
    description = "Login appservice -> token lie a un appareil sur @marc (une seule fois)";
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
