# services/matrix-hermes/default.nix
# Accès de l'agent Hermes au serveur Matrix de tower.
#
# Principe : un compte admin dédié @hermes-admin est créé automatiquement au boot à
# partir du registration_shared_secret de Synapse (le secret vit dans
# /var/lib/matrix-synapse/secrets.yaml, lisible par root seulement, d'où le
# service root). Son access_token est déposé dans un fichier lisible par le seul
# utilisateur hermes. Aucun mot de passe de marc n'est nécessaire pour ça.
#
# À partir de ce token, l'admin API de Synapse permet entre autres de fabriquer
# un token pour n'importe quel compte local, @marc compris :
#   POST /_synapse/admin/v1/users/@marc:matrix.marcpartensky.com/login
# (cf. skill hermes-matrix-access pour les commandes prêtes à l'emploi)
{
  config,
  pkgs,
  lib,
  ...
}: let
  dataDir = "/var/lib/hermes/.matrix";
  baseUrl = "http://127.0.0.1:8008";
  serverName = config.services.matrix-synapse.settings.server_name;
  # compte dédié, distinct du bot @hermes créé côté services/hermes (qui n'est
  # pas admin) : celui-ci est le point d'entrée admin de l'agent.
  adminUser = "hermes-admin";
  # compte bot existant, promu admin par ce service pour que son token sops
  # serve aussi à administrer le serveur
  promoteUser = "hermes";

  # Outil unique pour parler à l'API Matrix depuis une session Hermes :
  # mxc api/as/rooms/users/members/info/send (cf. skill hermes-matrix-access)
  mxc = pkgs.writeShellScriptBin "mxc" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [pkgs.curl pkgs.jq pkgs.coreutils]}:$PATH
    base="''${MATRIX_BASE:-${baseUrl}}"
    dir="${dataDir}"
    server="${serverName}"
    admin_token="$dir/admin_token"

    die() { echo "mxc: $*" >&2; exit 1; }

    [ -r "$admin_token" ] || die "token admin illisible ($admin_token)"

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
      [ -n "$tok" ] || die "pas de token pour $localpart"
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
mxc <commande> [args]
  api <methode> <chemin> [json]   appel brut avec le token admin
  as <localpart>                  access token d'un compte local (@marc par ex.)
  rooms [limite]                  liste des salles du serveur
  users [limite]                  liste des comptes locaux
  members <room_id>               membres d'une salle
  info <room_id>                  details d'une salle
  send <room_id> <texte>          envoie un message en tant que @marc
                                  (salles NON chiffrees uniquement : sur une salle
                                  chiffree, un client sans E2EE passe mal)
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
          | jq -r '.rooms[] | "\(.room_id)\t\(.name // "-")\t\(.joined_members) membres"'
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
        die "commande inconnue : $cmd (voir mxc help)"
        ;;
    esac
  '';
in {
  environment.systemPackages = [mxc];

  systemd.services.matrix-hermes-admin-token = {
    description = "Compte admin Matrix @hermes-admin et token d'API pour l'agent";
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
      # pas d'After=network-online : on tape en loopback sur synapse local
    };

    script = ''
      set -euo pipefail
      base=${baseUrl}
      dir=${dataDir}

      install -d -m 700 -o hermes -g hermes "$dir"

      urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

      # promeut le compte bot @hermes en admin du serveur ; idempotent
      promote() {
        local token="$1"
        local target
        target=$(urlencode "@${promoteUser}:${serverName}")
        local isadmin
        isadmin=$(curl -s -H "Authorization: Bearer $token" \
          "$base/_synapse/admin/v2/users/$target" | jq -r '.admin // false')
        if [ "$isadmin" = true ]; then
          echo "@${promoteUser} déjà admin"
          return 0
        fi
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
          -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
          -d '{"admin": true}' \
          "$base/_synapse/admin/v1/users/$target/admin" || true)
        echo "promotion admin de @${promoteUser} : http $code"
      }

      # idempotence : si le token en place fonctionne encore, ne rien recréer
      # (sinon on ajouterait un appareil à chaque boot)
      if [ -s "$dir/admin_token" ]; then
        token=$(cat "$dir/admin_token")
        code=$(curl -s -o /dev/null -w '%{http_code}' \
          -H "Authorization: Bearer $token" \
          "$base/_synapse/admin/v1/server_version" || true)
        if [ "$code" = 200 ]; then
          echo "token admin @${adminUser} toujours valide"
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
        echo "registration_shared_secret introuvable, abandon"
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
        echo "compte @${adminUser} créé (admin)"
      else
        # 400 : le compte existe déjà, on se connecte simplement dessus
        token=$(curl -s -X POST -H 'Content-Type: application/json' \
          -d "$(jq -n --arg u "${adminUser}" --arg p "$password" \
                '{type: "m.login.password", identifier: {type: "m.id.user", user: $u}, password: $p, device_id: "HERMESAGENT"}')" \
          "$base/_matrix/client/v3/login" | jq -r '.access_token // empty')
        echo "compte @${adminUser} déjà présent, connexion (register http $code)"
      fi
      rm -f "$response"

      if [ -z "$token" ] || [ "$token" = null ]; then
        echo "échec : aucun access_token obtenu"
        exit 1
      fi

      umask 177
      printf '%s' "$token" > "$dir/admin_token"
      write_secret "$dir/admin_token"

      promote "$token"

      # petit rappel sur disque de ce à quoi sert ce compte
      cat > "$dir/README" <<'EOF'
admin_token              access_token du compte admin @hermes-admin (0400 hermes)
hermes_admin_password    mot de passe de @hermes-admin, généré par le service
cf. skill hermes-matrix-access pour les appels admin API prêts à l'emploi
EOF
      chown hermes:hermes "$dir/README"
      chmod 400 "$dir/README"
    '';
  };

  # Le mot de passe de @marc, nécessaire au login de pantalaimon (proxy E2EE).
  # Volontairement commenté tant que la clé n'existe pas dans secrets/tower.yml :
  # sops-nix fait échouer l'activation si un secret déclaré est absent du fichier.
  #
  # sops.secrets."matrix_marc_password" = {
  #   owner = "hermes";
  #   group = "hermes";
  #   mode = "0400";
  # };
}