# services/gotify-matrix/default.nix
#
# Bidirectional Gotify <-> Matrix bridge, pivot = the encrypted room "🪽 Hermes"
# (!bHIbXBYEcLDiMFtbse, members: @marc and the gateway bot @hermes).
#
# DIRECTION Gotify -> Matrix: a systemd service (User=hermes) queries the
# local Gotify API (`GET /message?since=<id>`) and copies each notification
# into the room with `hermes send --to matrix:<room>`, which reuses the
# gateway credentials (token + E2EE device "Hermes Agent") without
# duplicating anything in this repo.
#   KNOWN PITFALL (tools/send_message_senders.py:522): outside the
#   gateway process, a Matrix send opens an EPHEMERAL E2EE connection. It is the
#   path intended for cron-type sends (low volume); a BURST
#   of ephemeral sends exhausts the recipient's one-time keys and can make
#   messages be lost silently. That is why the relay GROUPS the
#   notifications (GOTIFY_PONT_BATCH window) instead of opening a connection
#   per message: a burst of alerts = a single Matrix send. The
#   `since` cursor only advances after a successful send, so nothing is lost.
#
# DIRECTION Matrix -> Gotify: gateway hook vendored in services/hermes
# (`hooks/gotify-notify`): any text the agent publishes in this room is
# pushed into Gotify (hence onto marc's phone via the Gotify app). See
# the services/hermes module for the hook installation.
#
# TOKENS: Gotify exports nothing via sops and the API does not accept the
# admin password for /message or /stream. We therefore PROVISION both tokens at
# activation (root unit, idempotent) with the admin password (sops
# secret `gotify/admin_password`, already declared by services/gotify) via the
# local API: an APPLICATION (push) and a CLIENT (read messages). Nothing
# secret goes into the repo, and a Gotify database rebuilt from scratch
# reprovisions itself at the next switch.
#
# Troubleshooting:
#   journalctl -u gotify-pont-provision -n 30     # tokens created/reused
#   journalctl -u gotify-matrix-relay -f          # reading Gotify + sends
#   curl -s -H "X-Gotify-Key: $(cat /var/lib/gotify-pont/client_token)" \
#     'http://127.0.0.1:8070/message?limit=5'     # read the queue (hermes)
#   # verify the bridge end to end (direction Gotify -> Matrix): the notification
#   # must appear in the room within a few seconds
#   curl -s -H "X-Gotify-Key: $(cat /var/lib/gotify-pont/ping_token)" \
#     -H 'Content-Type: application/json' \
#     -d '{"title":"ping","message":"test du pont"}' \
#     http://127.0.0.1:8070/message
{
  pkgs,
  config,
  lib,
  ...
}: let
  cfg = config.services.gotifyMatrix;
  hermesBin = "${config.services.hermes-agent.package}/bin/hermes";

  # --- token provisioning (root, idempotent) ---
  provision = pkgs.writeShellScript "gotify-pont-provision" ''
    set -euo pipefail
    # systemd unit: the default PATH contains neither coreutils nor curl
    # (verified: `curl: command not found`, status=127).
    export PATH=${lib.makeBinPath [pkgs.coreutils pkgs.curl pkgs.jq pkgs.util-linux pkgs.apacheHttpd]}:$PATH
    API=${cfg.gotifyUrl}
    DIR=${cfg.stateDir}
    SECRET=${config.sops.secrets."gotify-matrix/admin_password".path}

    install -d -m 0755 "$DIR"
    if [ ! -r "$SECRET" ]; then
      echo "gotify-pont: secret $SECRET unreadable" >&2
      exit 1
    fi
    PW=$(cat "$SECRET")
    if [ -z "$PW" ]; then
      echo "gotify-pont: empty admin password" >&2
      exit 1
    fi

    # Wait for API availability: After=/Requires= on gotify-server.service
    # only guarantees that the PROCESS has started, not that the port already listens
    # (real outage on 16/11: provision launched 23s before gotify-server
    # responded, curl fails with exit 7/connection refused under `set -e`, bridge
    # INACTIVE until the next reboot). We actively wait for the port before
    # continuing, bounded to 60s.
    for _ in $(seq 1 30); do
      curl -fsS -o /dev/null "$API/health" 2>/dev/null && break
      sleep 2
    done

    # 1 = Gotify's postgres cluster is on THIS host (reading accounts and
    # aligning the hash are possible). 0 = remote database (VPS): we can only
    # authenticate with the sops secret.
    LOCAL_DB=${if cfg.localDatabase then "1" else "0"}

    # The local Gotify account was renamed marc@marcpartensky.com (OIDC
    # attachment, cf services/gotify). The API returns the SAME 401 for an unknown name and
    # for a wrong password: so we ask the database for the names (read
    # only, as postgres - the unit runs as root) and we try
    # each one, rather than hardcoding a name that can change.
    DB_USERS=""
    if [ "$LOCAL_DB" = 1 ]; then
      DB_USERS=$(runuser -u postgres -- ${config.services.postgresql.package}/bin/psql \
        -qAt -d gotify -c 'select name from users order by id' 2>/dev/null | tr '\n' ' ') || true
    fi
    echo "gotify-pont: local Gotify accounts = [$DB_USERS ${cfg.gotifyUser}]"

    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT

    AUTH_USER=""
    for name in $DB_USERS ${cfg.gotifyUser} admin marc; do
      code=$(curl -s -o "$TMP/probe.json" -w '%{http_code}' -u "$name:$PW" "$API/client")
      echo "gotify-pont: trying account $name -> HTTP $code"
      if [ "$code" = 200 ]; then
        AUTH_USER=$name
        break
      fi
    done
    if [ -z "$AUTH_USER" ]; then
      if [ "$LOCAL_DB" != 1 ]; then
        echo "gotify-pont: admin auth refused and DISTANT database (hash alignment impossible here), bridge INACTIVE" >&2
        exit 0
      fi
      # The admin password is no longer the one from creation (changed in the UI
      # afterwards - observed on 11/11/2026: the tower.yml secret no longer
      # validates, even though the account exists and bcrypt does compare a hash).
      # So we ALIGN the database hash with the bridge's sops secret, as
      # gotify-db-password already aligns the postgres role of the same database.
      ADMIN_NAME=$(runuser -u postgres -- ${config.services.postgresql.package}/bin/psql \
        -qAt -d gotify -c 'select name from users where admin = true order by id limit 1' 2>/dev/null \
        | head -1) || true
      if [ -z "$ADMIN_NAME" ]; then
        echo "gotify-pont: no admin account in the database, bridge INACTIVE" >&2
        exit 0
      fi
      HASH=$(htpasswd -bnBC 10 "" "$PW" | tr -d ':\n')
      case "$HASH" in
        \$2*) ;;
        *)
          echo "gotify-pont: unexpected bcrypt hash, bridge INACTIVE" >&2
          exit 0
          ;;
      esac
      # psql only interpolates variables (`:'h'`) on stdin/`-f`, NOT with
      # `-c` (error seen: "syntax error at or near ':'"). No here-doc
      # here: in an indented Nix string, a dedented terminator breaks
      # (bash no longer recognizes it) - a simple printf suffices.
      printf "update users set pass = :'h' where name = :'uname';\n" \
        | runuser -u postgres -- ${config.services.postgresql.package}/bin/psql -q -d gotify \
          -v uname="$ADMIN_NAME" -v h="$HASH" -f -
      echo "gotify-pont: hash of account $ADMIN_NAME aligned with the sops secret"
      code=$(curl -s -o "$TMP/probe2.json" -w '%{http_code}' -u "$ADMIN_NAME:$PW" "$API/client")
      if [ "$code" != 200 ]; then
        echo "gotify-pont: auth still failing after alignment (HTTP $code), bridge INACTIVE" >&2
        exit 0
      fi
      AUTH_USER=$ADMIN_NAME
    fi
    echo "gotify-pont: auth admin OK ($AUTH_USER)"

    # The token FILE is authoritative: Gotify NEVER returns the tokens in its
    # list responses (`GET /client` and `GET /application` carry id and name,
    # not `token`), so "finding the existing token by its name" is
    # impossible - logic that relies on it creates a duplicate at each activation and
    # rotates the tokens (experienced). So we reuse the file as-is, and we
    # only create as a fallback; in that case we first delete the entries with the same
    # name (their tokens are lost, we cannot recover them).
    # `validate` = "message": the token is verified by a GET /message (possible
    # for a CLIENT token; an APPLICATION token can only post, so we
    # take it on faith to avoid injecting a notification at each switch).
    get_or_create() {
      res=$1; name=$2; out=$3; validate=$4
      if [ -s "$out" ]; then
        if [ "$validate" = message ]; then
          if curl -fsS -o /dev/null -H "X-Gotify-Key: $(cat "$out")" "$API/message?limit=1"; then
            echo "gotify-pont: $res \"$name\": existing token valid (reused)"
            return 0
          fi
          echo "gotify-pont: $res \"$name\": existing token REFUSED, recreating"
        else
          echo "gotify-pont: $res \"$name\": existing token reused ($out)"
          return 0
        fi
      fi
      code=$(curl -s -o "$TMP/$res.json" -w '%{http_code}' -u "$AUTH_USER:$PW" "$API/$res" || echo 000)
      echo "gotify-pont: $res $name -> HTTP $code"
      for id in $(jq -r --arg n "$name" \
        'if type == "array" then (.[] | select(.name == $n) | .id) else empty end' \
        "$TMP/$res.json" 2>/dev/null || true); do
        echo "gotify-pont: deleting stale entry $res id=$id"
        curl -s -o /dev/null -X DELETE -u "$AUTH_USER:$PW" "$API/$res/$id"
      done
      echo "gotify-pont: creating $res \"$name\""
      curl -s -o "$TMP/$res.json" -u "$AUTH_USER:$PW" \
        -H 'Content-Type: application/json' -d "{\"name\": \"$name\"}" "$API/$res"
      token=$(jq -r '.token // empty' "$TMP/$res.json" 2>/dev/null || true)
      if [ -z "$token" ]; then
        echo "gotify-pont: no token returned by $res, bridge INACTIVE" >&2
        exit 0
      fi
      printf '%s' "$token" > "$out"
      chown hermes:hermes "$out"
      chmod 0400 "$out"
      echo "gotify-pont: token $res written ($(wc -c < "$out") bytes)"
    }

    get_or_create client ${cfg.clientName} "$DIR/client_token" message
    get_or_create application ${cfg.applicationName} "$DIR/application_token" ""
    # "ping" Application: used to VERIFY the bridge on demand (a
    # notification emitted with this token must appear in the room) without having
    # to log in as admin. The relay does not ignore it (only the bridge
    # application is filtered, to cut the echo).
    get_or_create application "${cfg.applicationName}-ping" "$DIR/ping_token" ""

    # appid -> name table, so that the relay names the notification source
    curl -s -u "$AUTH_USER:$PW" "$API/application" \
      | jq -c '[.[] | {id, name}]' > "$DIR/applications.json"
    chmod 0644 "$DIR/applications.json"
    echo "gotify-pont: applications.json up to date"

    # Id of OUR application: the relay uses it to avoid copying into the
    # room the notifications that the hook itself pushed there (echo).
    jq -r --arg n "${cfg.applicationName}" '.[] | select(.name == $n) | .id' \
      "$DIR/applications.json" | head -1 > "$DIR/appid"
    chmod 0444 "$DIR/appid"
    echo "gotify-pont: bridge application id=$(cat "$DIR/appid")"
  '';

  # --- Gotify -> Matrix relay ---
  relay = pkgs.writers.writePython3Bin "gotify-matrix-relay" {
    flakeIgnore = ["E501"];
  } ''
    # Gotify -> Matrix relay: reads the Gotify notification queue via
    # the local API and copies the new ones into the bridge's Matrix room.
    # See the header of the services/gotify-matrix module for why we
    # group (batch window) and for the `since` cursor.
    import json
    import os
    import time
    import urllib.request
    from subprocess import run

    API = os.environ.get("GOTIFY_PONT_URL", "http://127.0.0.1:8070")
    DIR = os.environ.get("GOTIFY_PONT_DIR", "/var/lib/gotify-pont")
    STATE = os.environ.get("GOTIFY_PONT_STATE", "/var/lib/gotify-matrix-relay/last_message_id")
    ROOM = os.environ.get("GOTIFY_PONT_ROOM", "")
    HERMES = os.environ.get("HERMES_BIN", "hermes")
    POLL = int(os.environ.get("GOTIFY_PONT_POLL", "10"))
    BATCH = float(os.environ.get("GOTIFY_PONT_BATCH", "3"))
    PAGE = 50
    SEND_TIMEOUT = 180


    def log(message):
        print("[gotify-matrix-relay] " + message, flush=True)


    def token_path():
        return os.path.join(DIR, "client_token")


    def read_token():
        with open(token_path(), encoding="utf-8") as handle:
            return handle.read().strip()


    def app_names():
        try:
            with open(os.path.join(DIR, "applications.json"), encoding="utf-8") as handle:
                return {int(item["id"]): item["name"] for item in json.load(handle)}
        except Exception as exc:
            log("applications.json unreadable (%s): sources numbered" % exc)
            return {}


    def read_state():
        try:
            with open(STATE, encoding="utf-8") as handle:
                return int(handle.read().strip())
        except Exception:
            return None


    def write_state(value):
        tmp = STATE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(str(value))
        os.replace(tmp, STATE)


    def api_get(token, path):
        request = urllib.request.Request(API + path, headers={"X-Gotify-Key": token})
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.load(response)
        # GET /message returns an OBJECT {"messages": [...], "paging": {...}}: iterating
        # the response directly crashes the relay (experienced: "string indices
        # must be integers, not 'str'").
        if isinstance(payload, dict):
            return list(payload.get("messages") or [])
        return list(payload)


    def newest_id(token):
        """Id of the most recent message (0 if the queue is empty)."""
        messages = api_get(token, "/message?since=0&limit=%d" % PAGE)
        return max([int(item["id"]) for item in messages] or [0])


    def fetch_after(token, after):
        """Messages with id STRICTLY greater than `after`, from oldest to
        newest.

        Gotify API PITFALL: `since=N` returns messages with id < N, from newest
        to oldest (`since=0` = the latest ones). So there is no
        "everything newer than N": we walk down the pages as long as the
        oldest id seen stays above the cursor, then we return the list
        sorted back in increasing order.
        """
        collected = []
        since = 0
        while True:
            messages = api_get(token, "/message?since=%d&limit=%d" % (since, PAGE))
            if not messages:
                break
            collected.extend(item for item in messages if int(item["id"]) > after)
            oldest = min(int(item["id"]) for item in messages)
            if oldest <= after or len(messages) < PAGE:
                break
            since = oldest
        collected.sort(key=lambda item: int(item["id"]))
        return collected


    def label(message, names):
        appid = int(message.get("appid") or 0)
        return names.get(appid) or ("app %s" % appid)


    def format_batch(messages, names):
        if len(messages) == 1:
            message = messages[0]
            priority = message.get("priority") or 0
            mark = "🚨" if priority >= 8 else "🔔"
            title = (message.get("title") or "").strip() or "(no title)"
            head = "%s Gotify · %s — %s" % (mark, label(message, names), title)
            body = (message.get("message") or "").strip()
            return head + "\n" + body if body else head
        lines = ["🔔 Gotify · %d notifications" % len(messages)]
        for message in messages:
            priority = message.get("priority") or 0
            mark = "🚨" if priority >= 8 else "·"
            title = (message.get("title") or "").strip() or "(no title)"
            lines.append("%s %s — %s" % (mark, label(message, names), title))
            body = (message.get("message") or "").strip()
            if body:
                lines.append("    " + " ".join(body.split()))
        return "\n".join(lines)


    def deliver(text):
        try:
            result = run([HERMES, "send", "--to", "matrix:" + ROOM, text],
                         capture_output=True, text=True, timeout=SEND_TIMEOUT)
        except Exception as exc:
            log("Matrix send impossible: %s" % exc)
            return False
        if result.returncode != 0:
            log("hermes send exit=%d stderr=%s" % (result.returncode, result.stderr.strip()[:300]))
            return False
        log("sent to Matrix (%d characters)" % len(text))
        return True


    def own_appid():
        """Id of OUR Gotify application (the one where the hook pushes the agent's
        responses). The relay must ignore it, otherwise each Matrix response goes back into
        Gotify (hook) then comes back into the room (relay): visible echo.
        The id is written by provisioning ($DIR/appid)."""
        try:
            with open(os.path.join(DIR, "appid"), encoding="utf-8") as handle:
                return int(handle.read().strip())
        except Exception:
            return None


    def drop_own(messages, own):
        if not isinstance(own, int):
            return list(messages)
        kept = [item for item in messages if int(item.get("appid") or 0) != own]
        if len(kept) != len(messages):
            log("anti-echo: %d message(s) from the bridge application ignored"
                % (len(messages) - len(kept)))
        return kept


    def main():
        log("starting: API=%s room=%s" % (API, ROOM))
        names = app_names()
        own = own_appid()
        log("bridge application (ignored by the relay): %s" % own)
        since = read_state()
        if since is None:
            # First startup: we do not flood the room with history,
            # we start from the last message known to Gotify.
            while True:
                if not os.path.exists(token_path()):
                    log("client token absent (%s): bridge inactive, retrying in 60s"
                        % token_path())
                    time.sleep(60)
                    continue
                try:
                    since = newest_id(read_token())
                    break
                except Exception as exc:
                    log("priming impossible (%s), retrying in %ds" % (exc, POLL))
                    time.sleep(POLL)
            write_state(since)
            log("priming: starting at message #%d (history ignored)" % since)
        cycles = 0
        while True:
            cycles += 1
            if cycles % 60 == 0:
                names = app_names()
                own = own_appid()
            if not os.path.exists(token_path()):
                log("client token absent (%s): bridge inactive, retrying in 60s"
                    % token_path())
                time.sleep(60)
                continue
            try:
                raw = fetch_after(read_token(), since)
            except Exception as exc:
                log("Gotify read failed (%s), retrying in %ds" % (exc, POLL))
                time.sleep(POLL)
                continue
            if not raw:
                time.sleep(POLL)
                continue
            # The cursor advances even if everything is filtered: otherwise the messages from
            # our own application would be re-read on each round.
            highest = max(int(item["id"]) for item in raw)
            batch = drop_own(raw, own)
            if batch:
                # group the burst: a single E2EE connection on the gateway side
                time.sleep(BATCH)
                try:
                    extra = drop_own(fetch_after(read_token(), highest), own)
                    known = {int(item["id"]) for item in batch}
                    batch += [item for item in extra if int(item["id"]) not in known]
                    highest = max([highest] + [int(item["id"]) for item in extra])
                except Exception:
                    pass
                batch.sort(key=lambda item: int(item["id"]))
                if not deliver(format_batch(batch, names)):
                    log("send failed: retrying on the next round")
                    time.sleep(POLL * 3)
                    continue
            since = highest
            write_state(since)
            time.sleep(POLL)


    if __name__ == "__main__":
        main()
  '';

in {
  options.services.gotifyMatrix = {
    # Active by import (repo convention): turn off with
    # `services.gotifyMatrix.enable = false;` on a host that imports
    # the aggregator without wanting the bridge.
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enables the Gotify <-> Matrix bridge (room '🪽 Hermes').";
    };

    room = lib.mkOption {
      type = lib.types.str;
      default = "!bHIbXBYEcLDiMFtbse:matrix.marcpartensky.com";
      description = "Matrix room of the bridge (encrypted; @marc + @hermes).";
    };

    gotifyUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8070";
      description = "Local Gotify API (the service binds 127.0.0.1).";
    };

    # Is Gotify's postgres cluster on THIS host? true on a host that
    # hosts the server, false on a simple consumer (tower since the
    # move to the VPS): disables reading accounts from the database and
    # bcrypt alignment, which only make sense locally.
    localDatabase = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Gotify's postgres cluster is local to this host.";
    };

    gotifyUser = lib.mkOption {
      type = lib.types.str;
      default = "marc@marcpartensky.com";
      description = "Gotify admin account for the API basic auth (renamed on OIDC attachment).";
    };

    clientName = lib.mkOption {
      type = lib.types.str;
      default = "hermes-matrix-relay";
      description = "Name of the Gotify client (read token) created by provisioning.";
    };

    applicationName = lib.mkOption {
      type = lib.types.str;
      default = "hermes-matrix-pont";
      description = "Name of the Gotify application (push token) created by provisioning.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/gotify-pont";
      description = "Directory of provisioned tokens (root, tokens in 0400 hermes).";
    };

    pollSeconds = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Interval for reading the Gotify queue.";
    };

    batchSeconds = lib.mkOption {
      type = lib.types.float;
      default = 3.0;
      description = "Grouping window for a burst of notifications (a single Matrix send).";
    };
  };

  config = lib.mkIf (cfg.enable && config.services.gotify.enable) {
    # LOCAL password of the Gotify admin account (dedicated sops file, encrypted
    # to tower only). It is only used for automation: marc logs in
    # via OIDC (Zitadel). The gotify-pont-provision unit (root) uses it to
    # create the tokens, and ALIGNS the database bcrypt hash if the
    # historical password is no longer known - same pattern as gotify-db-password, which
    # already aligns the postgres role of the same database to a sops secret.
    # (The `gotify/admin_password` secret in tower.yml stays in place for
    # GOTIFY_DEFAULTUSER_PASS, which is only used to create a fresh database:
    # it no longer matches the current password, as observed in 11/2026.)
    sops.secrets."gotify-matrix/admin_password" = {
      # Same file as services/gotify: a single value for the admin
      # account, whether the server is local (database creation) or remote (basic
      # auth for provisioning calls).
      sopsFile = ../../secrets/gotify.yml;
      key = "gotify_admin_password";
    };

    # --- Gotify tokens (application + client), provisioned as root ---
    # A root oneshot: it reads the admin password (sops, root-only) and talks
    # to the local API. Idempotent: it reuses the tokens already present.
    systemd.services.gotify-pont-provision = {
      description = "Provisions the Gotify tokens of the Matrix bridge (application + client)";
      wantedBy = ["multi-user.target"];
      # gotify-server only exists IF the server runs on this host: on
      # tower (remote database) the dependency pointed into the void. The script
      # waits for the API via curl anyway (60 s loop).
      after = lib.optional cfg.localDatabase "gotify-server.service";
      requires = lib.optional cfg.localDatabase "gotify-server.service";
      before = ["gotify-matrix-relay.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = provision;
      };
    };

    # --- Gotify -> Matrix relay ---
    systemd.services.gotify-matrix-relay = {
      description = "Gotify -> Matrix room 'Hermes' relay (hermes send)";
      wantedBy = ["multi-user.target"];
      after = ["gotify-pont-provision.service" "matrix-synapse.service"];
      wants = ["gotify-pont-provision.service"];
      requires = ["gotify-pont-provision.service"];
      serviceConfig = {
        User = "hermes";
        Group = "hermes";
        ExecStart = "${relay}/bin/gotify-matrix-relay";
        # never a voluntary exit: we restart if the process dies
        Restart = "always";
        RestartSec = 10;
        # State of the `since` cursor (the process writes a file): directory
        # owned by hermes, distinct from /var/lib/gotify-pont (root).
        StateDirectory = "gotify-matrix-relay";
        StateDirectoryMode = "0750";
        # `hermes send` needs its home (token, E2EE device, state.db):
        # no ProtectHome or hardened ProtectSystem here.
        Environment = [
          "HERMES_BIN=${hermesBin}"
          "GOTIFY_PONT_ROOM=${cfg.room}"
          "GOTIFY_PONT_URL=${cfg.gotifyUrl}"
          "GOTIFY_PONT_STATE=/var/lib/gotify-matrix-relay/last_message_id"
          "GOTIFY_PONT_POLL=${toString cfg.pollSeconds}"
          "GOTIFY_PONT_BATCH=${toString cfg.batchSeconds}"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}
