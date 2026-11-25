# services/matrix-hermes/default.nix
# Access of the Hermes agent to tower's Matrix server.
#
# Principle: a dedicated admin account @hermes-admin is created automatically at boot
# from Synapse's registration_shared_secret (the secret lives in
# /var/lib/matrix-synapse/secrets.yaml, readable by root only, hence the
# root service). Its access_token is deposited in a file readable by the
# hermes user only. No marc password is needed for that.
#
# From this token, the Synapse admin API allows, among other things, forging
# a token for any local account, including @marc:
#   POST /_synapse/admin/v1/users/@marc:matrix.marcpartensky.com/login
# (cf. skill hermes-matrix-access for ready-to-use commands)
{
  config,
  pkgs,
  lib,
  ...
}: let
  dataDir = "/var/lib/hermes/.matrix";
  baseUrl = "http://127.0.0.1:8008";
  serverName = config.services.matrix-synapse.settings.server_name;
  # dedicated account, distinct from the @hermes bot created in services/hermes
  # (which is not admin): this one is the agent's admin entry point.
  adminUser = "hermes-admin";
  # existing bot account, promoted to admin by this service so that its sops token
  # also serves to administer the server
  promoteUser = "hermes";

  # Single tool to talk to the Matrix API from a Hermes session:
  # mxc api/as/rooms/users/members/info/send (cf. skill hermes-matrix-access)
  mxc = pkgs.writeShellScriptBin "mxc" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [pkgs.curl pkgs.jq pkgs.coreutils]}:$PATH
    base="''${MATRIX_BASE:-${baseUrl}}"
    dir="${dataDir}"
    server="${serverName}"
    admin_token="$dir/admin_token"

    die() { echo "mxc: $*" >&2; exit 1; }

    [ -r "$admin_token" ] || die "admin token unreadable ($admin_token)"

    api() {
      local method="$1" path="$2" body="''${3:-}"
      if [ -n "$body" ]; then
        curl -s -X "$method" -H "Authorization: Bearer $(cat "$admin_token")" \
          -H 'Content-Type: application/json' -d "$body" "$base$path"
      else
        curl -s -X "$method" -H "Authorization: Bearer $(cat "$admin_token")" "$base$path"
      fi
    }

    token_for() {
      local localpart="$1"
      local cache="$dir/token_$localpart"
      local uid
      if [ -s "$cache" ]; then
        uid=$(curl -s -H "Authorization: Bearer $(cat "$cache")" \
          "$base/_matrix/client/v3/account/whoami" | jq -r '.user_id // empty')
        if [ "$uid" = "@$localpart:$server" ]; then
          cat "$cache"
          return 0
        fi
      fi
      uid=$(jq -rn --arg v "@$localpart:$server" '$v|@uri')
      local tok
      tok=$(api POST "/_synapse/admin/v1/users/$uid/login" \
        "$(jq -n --arg d "MXC-$localpart" '{device_id: $d}')" | jq -r '.access_token // empty')
      [ -n "$tok" ] || die "no token for $localpart"
      umask 077
      printf '%s' "$tok" > "$cache"
      chmod 400 "$cache"
      printf '%s' "$tok"
    }

    cmd="''${1:-help}"
    shift || true
    case "$cmd" in
      help|-h|--help)
        cat <<'EOF'
mxc <command> [args]
  api <method> <path> [json]      raw call with the admin token
  as <localpart>                  access token of a local account (@marc for ex.)
  rooms [limit]                   list of the server's rooms
  users [limit]                   list of local accounts
  members <room_id>               members of a room
  info <room_id>                  details of a room
  send <room_id> <text>           sends a message as @marc
                                  (NON encrypted rooms only: on an encrypted
                                  room, a client without E2EE does poorly)
EOF
        ;;
      api)
        api "$1" "$2" "''${3:-}"
        ;;
      as)
        token_for "$1"
        ;;
      rooms)
        api GET "/_synapse/admin/v1/rooms?limit=''${1:-100}" \
          | jq -r '.rooms[] | "\(.room_id)\t\(.name // "-")\t\(.joined_members) members"'
        ;;
      users)
        api GET "/_synapse/admin/v2/users?limit=''${1:-100}" \
          | jq -r '.users[] | "\(.name)\tadmin=\(.admin)"'
        ;;
      members)
        room=$(jq -rn --arg v "$1" '$v|@uri')
        api GET "/_synapse/admin/v1/rooms/$room/members" | jq -r '.members[]'
        ;;
      info)
        room=$(jq -rn --arg v "$1" '$v|@uri')
        api GET "/_synapse/admin/v1/rooms/$room" | jq .
        ;;
      send)
        room="$1"
        shift
        tok=$(token_for marc)
        room_enc=$(jq -rn --arg v "$room" '$v|@uri')
        txn=$(date +%s%N)
        curl -s -X PUT -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
          -d "$(jq -Rn --arg b "$*" '{msgtype: "m.text", body: $b}')" \
          "$base/_matrix/client/v3/rooms/$room_enc/send/m.room.message/mxc$txn" \
          | jq -c '{event_id}'
        ;;
      *)
        die "unknown command: $cmd (see mxc help)"
        ;;
    esac
  '';
in {
  environment.systemPackages = [mxc];

  systemd.services.matrix-hermes-admin-token = {
    description = "Matrix admin account @hermes-admin and API token for the agent";
    wantedBy = ["multi-user.target"];
    after = ["matrix-synapse.service"];
    requires = ["matrix-synapse.service"];

    path = [
      pkgs.curl
      pkgs.jq
      pkgs.gawk
      pkgs.openssl
      pkgs.coreutils
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # no After=network-online: we hit local synapse over loopback
    };

    script = ''
      set -euo pipefail
      base=${baseUrl}
      dir=${dataDir}

      install -d -m 700 -o hermes -g hermes "$dir"

      urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

      # promotes the @hermes bot account to server admin; idempotent
      promote() {
        local token="$1"
        local target
        target=$(urlencode "@${promoteUser}:${serverName}")
        local isadmin
        isadmin=$(curl -s -H "Authorization: Bearer $token" \
          "$base/_synapse/admin/v2/users/$target" | jq -r '.admin // false')
        if [ "$isadmin" = true ]; then
          echo "@${promoteUser} already admin"
          return 0
        fi
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
          -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
          -d '{"admin": true}' \
          "$base/_synapse/admin/v1/users/$target/admin" || true)
        echo "admin promotion of @${promoteUser}: http $code"
      }

      # idempotence: if the token in place still works, recreate nothing
      # (otherwise a device would be added on every boot)
      if [ -s "$dir/admin_token" ]; then
        token=$(cat "$dir/admin_token")
        code=$(curl -s -o /dev/null -w '%{http_code}' \
          -H "Authorization: Bearer $token" \
          "$base/_synapse/admin/v1/server_version" || true)
        if [ "$code" = 200 ]; then
          echo "admin token @${adminUser} still valid"
          promote "$token"
          exit 0
        fi
      fi

      write_secret() {
        chown hermes:hermes "$1"
        chmod 400 "$1"
      }

      secret=$(sed -n 's/^registration_shared_secret: *//p' /var/lib/matrix-synapse/secrets.yaml)
      if [ -z "$secret" ]; then
        echo "registration_shared_secret not found, aborting"
        exit 1
      fi

      if [ ! -s "$dir/hermes_admin_password" ]; then
        umask 177
        openssl rand -hex 24 > "$dir/hermes_admin_password"
      fi
      write_secret "$dir/hermes_admin_password"
      password=$(cat "$dir/hermes_admin_password")

      token=""
      response=$(mktemp)
      nonce=$(curl -s "$base/_synapse/admin/v1/register" | jq -r .nonce)
      mac=$(printf '%s\0%s\0%s\0%s' "$nonce" "${adminUser}" "$password" "admin" \
        | openssl dgst -sha1 -hmac "$secret" | awk '{print $NF}')
      code=$(curl -s -o "$response" -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        -d "$(jq -n --arg n "$nonce" --arg u "${adminUser}" --arg p "$password" --arg m "$mac" \
              '{nonce: $n, username: $u, password: $p, mac: $m, admin: true, inhibit_login: false}')" \
        "$base/_synapse/admin/v1/register" || true)

      if [ "$code" = 200 ]; then
        token=$(jq -r '.access_token // empty' "$response")
        echo "account @${adminUser} created (admin)"
      else
        # 400: the account already exists, we simply log in on it
        token=$(curl -s -X POST -H 'Content-Type: application/json' \
          -d "$(jq -n --arg u "${adminUser}" --arg p "$password" \
                '{type: "m.login.password", identifier: {type: "m.id.user", user: $u}, password: $p, device_id: "HERMESAGENT"}')" \
          "$base/_matrix/client/v3/login" | jq -r '.access_token // empty')
        echo "account @${adminUser} already present, login (register http $code)"
      fi
      rm -f "$response"

      if [ -z "$token" ] || [ "$token" = null ]; then
        echo "failure: no access_token obtained"
        exit 1
      fi

      umask 177
      printf '%s' "$token" > "$dir/admin_token"
      write_secret "$dir/admin_token"

      promote "$token"

      # small reminder on disk of what this account is for
      cat > "$dir/README" <<'EOF'
admin_token              access_token of the admin account @hermes-admin (0400 hermes)
hermes_admin_password    password of @hermes-admin, generated by the service
cf. skill hermes-matrix-access for ready-to-use admin API calls
EOF
      chown hermes:hermes "$dir/README"
      chmod 400 "$dir/README"
    '';
  };

  # The password of @marc, needed for the pantalaimon login (E2EE proxy).
  # Deliberately commented out as long as the key does not exist in secrets/tower.yml:
  # sops-nix fails the activation if a declared secret is absent from the file.
  #
  # sops.secrets."matrix_marc_password" = {
  #   owner = "hermes";
  #   group = "hermes";
  #   mode = "0400";
  # };
}