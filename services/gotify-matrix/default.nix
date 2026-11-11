# services/gotify-matrix/default.nix
#
# Pont bidirectionnel Gotify <-> Matrix, pivot = la salle chiffree « 🪽 Hermes »
# (!bHIbXBYEcLDiMFtbse, membres : @marc et le bot @hermes du gateway).
#
# SENS Gotify -> Matrix : un service systemd (User=hermes) interroge l'API
# locale de Gotify (`GET /message?since=<id>`) et recopie chaque notification
# dans la salle avec `hermes send --to matrix:<salle>`, qui reutilise les
# identifiants du gateway (token + appareil E2EE « Hermes Agent ») sans rien
# dupliquer dans ce depot.
#   PIEGE CONNU (tools/send_message_senders.py:522) : hors du process du
#   gateway, un envoi Matrix ouvre une connexion E2EE EPHEMERALE. C'est le
#   chemin prevu pour les envois type cron (faible volume) ; une RAFALE
#   d'envois ephemeres epuise les one-time keys du destinataire et peut faire
#   perdre des messages en silence. C'est pourquoi le relais REGROUPE les
#   notifications (fenetre GOTIFY_PONT_BATCH) au lieu d'ouvrir une connexion
#   par message : une rafale d'alertes = un seul envoi Matrix. Le curseur
#   `since` n'avance qu'apres un envoi reussi, donc rien n'est perdu.
#
# SENS Matrix -> Gotify : hook de gateway vendorise dans services/hermes
# (`hooks/gotify-notify`) : tout texte que l'agent publie dans cette salle est
# pousse dans Gotify (donc sur le telephone de marc via l'appli Gotify). Voir
# le module services/hermes pour l'installation du hook.
#
# JETONS : Gotify n'exporte rien par sops et l'API n'accepte pas le mot de
# passe admin pour /message ou /stream. On PROVISIONNE donc les deux jetons a
# l'activation (unite root, idempotente) avec le mot de passe admin (secret
# sops `gotify/admin_password`, deja declare par services/gotify) via l'API
# locale : une APPLICATION (pousser) et un CLIENT (lire les messages). Rien de
# secret n'entre dans le depot, et une base Gotify refaite a zero se
# reprovisionne toute seule au switch suivant.
#
# Depannage :
#   journalctl -u gotify-pont-provision -n 30     # jetons crees/reutilises
#   journalctl -u gotify-matrix-relay -f          # lecture Gotify + envois
#   curl -s -H "X-Gotify-Key: $(cat /var/lib/gotify-pont/client_token)" \
#     'http://127.0.0.1:8070/message?limit=5'     # lire la file (hermes)
{
  pkgs,
  config,
  lib,
  ...
}: let
  cfg = config.services.gotifyMatrix;
  hermesBin = "${config.services.hermes-agent.package}/bin/hermes";

  # --- provisionnement des jetons (root, idempotent) ---
  provision = pkgs.writeShellScript "gotify-pont-provision" ''
    set -euo pipefail
    # Unite systemd : le PATH par defaut ne contient ni coreutils ni curl
    # (verifie : `curl: command not found`, status=127).
    export PATH=${lib.makeBinPath [pkgs.coreutils pkgs.curl pkgs.jq pkgs.util-linux pkgs.apacheHttpd]}:$PATH
    API=${cfg.gotifyUrl}
    DIR=${cfg.stateDir}
    SECRET=${config.sops.secrets."gotify-matrix/admin_password".path}

    install -d -m 0755 "$DIR"
    if [ ! -r "$SECRET" ]; then
      echo "gotify-pont: secret $SECRET illisible" >&2
      exit 1
    fi
    PW=$(cat "$SECRET")
    if [ -z "$PW" ]; then
      echo "gotify-pont: mot de passe admin vide" >&2
      exit 1
    fi

    # Le compte local Gotify a ete renomme marc@marcpartensky.com (rattachement
    # OIDC, cf services/gotify). L'API rend le MEME 401 pour un nom inconnu et
    # pour un mot de passe faux : on demande donc les noms a la base (lecture
    # seule, en tant que postgres — l'unite tourne en root) et on essaie
    # chacun, plutot que de figer un nom qui peut changer.
    DB_USERS=""
    DB_USERS=$(runuser -u postgres -- ${config.services.postgresql.package}/bin/psql \
      -qAt -d gotify -c 'select name from users order by id' 2>/dev/null | tr '\n' ' ') || true
    echo "gotify-pont: comptes locaux Gotify = [$DB_USERS ${cfg.gotifyUser}]"

    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT

    AUTH_USER=""
    for name in $DB_USERS ${cfg.gotifyUser} admin marc; do
      code=$(curl -s -o "$TMP/probe.json" -w '%{http_code}' -u "$name:$PW" "$API/client")
      echo "gotify-pont: essai compte $name -> HTTP $code"
      if [ "$code" = 200 ]; then
        AUTH_USER=$name
        break
      fi
    done
    if [ -z "$AUTH_USER" ]; then
      # Le mot de passe admin n'est plus celui de la creation (change dans l'UI
      # apres coup — constate le 11/11/2026 : le secret de tower.yml ne valide
      # plus, alors que le compte existe et que bcrypt compare bien un hash).
      # On ALIGNE donc le hash de la base sur le secret sops du pont, comme
      # gotify-db-password aligne deja le role postgres de la meme base.
      ADMIN_NAME=$(runuser -u postgres -- ${config.services.postgresql.package}/bin/psql \
        -qAt -d gotify -c 'select name from users where admin = true order by id limit 1' 2>/dev/null \
        | head -1) || true
      if [ -z "$ADMIN_NAME" ]; then
        echo "gotify-pont: aucun compte admin en base, pont INACTIF" >&2
        exit 0
      fi
      HASH=$(htpasswd -bnBC 10 "" "$PW" | tr -d ':\n')
      case "$HASH" in
        \$2*) ;;
        *)
          echo "gotify-pont: hash bcrypt inattendu, pont INACTIF" >&2
          exit 0
          ;;
      esac
      # psql n'interpole les variables (`:'h'`) que sur stdin/`-f`, PAS avec
      # `-c` (erreur vue : « syntax error at or near ":" »). Pas de here-doc
      # ici : dans une chaine indentee Nix, un terminateur desindente casse
      # (bash ne le reconnait plus) — un simple printf suffit.
      printf "update users set pass = :'h' where name = :'uname';\n" \
        | runuser -u postgres -- ${config.services.postgresql.package}/bin/psql -q -d gotify \
          -v uname="$ADMIN_NAME" -v h="$HASH" -f -
      echo "gotify-pont: hash du compte $ADMIN_NAME aligne sur le secret sops"
      code=$(curl -s -o "$TMP/probe2.json" -w '%{http_code}' -u "$ADMIN_NAME:$PW" "$API/client")
      if [ "$code" != 200 ]; then
        echo "gotify-pont: auth toujours en echec apres alignement (HTTP $code), pont INACTIF" >&2
        exit 0
      fi
      AUTH_USER=$ADMIN_NAME
    fi
    echo "gotify-pont: auth admin OK ($AUTH_USER)"

    get_or_create() {
      res=$1; name=$2; out=$3
      curl -s -o "$TMP/$res.json" -u "$AUTH_USER:$PW" "$API/$res"
      token=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .token' "$TMP/$res.json" | head -1)
      if [ -z "$token" ] || [ "$token" = null ]; then
        echo "gotify-pont: creation $res \"$name\""
        curl -s -o "$TMP/$res.json" -u "$AUTH_USER:$PW" \
          -H 'Content-Type: application/json' -d "{\"name\": \"$name\"}" "$API/$res"
        token=$(jq -r '.token // empty' "$TMP/$res.json")
      else
        echo "gotify-pont: $res \"$name\" deja present (reutilise)"
      fi
      if [ -z "$token" ]; then
        echo "gotify-pont: aucun jeton rendu par $res" >&2
        exit 1
      fi
      printf '%s' "$token" > "$out"
      chown hermes:hermes "$out"
      chmod 0400 "$out"
      echo "gotify-pont: jeton $res ecrit ($(wc -c < "$out") octets)"
    }

    get_or_create client ${cfg.clientName} "$DIR/client_token"
    get_or_create application ${cfg.applicationName} "$DIR/application_token"

    # table appid -> nom, pour que le relais nomme la source de la notification
    curl -s -u "$AUTH_USER:$PW" "$API/application" \
      | jq -c '[.[] | {id, name}]' > "$DIR/applications.json"
    chmod 0644 "$DIR/applications.json"
    echo "gotify-pont: applications.json a jour"
  '';

  # --- relais Gotify -> Matrix ---
  relay = pkgs.writers.writePython3Bin "gotify-matrix-relay" {
    flakeIgnore = ["E501"];
  } ''
    # Relais Gotify -> Matrix : lit la file de notifications Gotify par
    # l'API locale et recopie les nouvelles dans la salle Matrix du pont.
    # Voir l'en-tete du module services/gotify-matrix pour le pourquoi du
    # regroupement (fenetre batch) et du curseur `since`.
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
            log("applications.json illisible (%s) : sources numerotees" % exc)
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


    def fetch(token, since):
        url = "%s/message?since=%d&limit=%d" % (API, since, PAGE)
        request = urllib.request.Request(url, headers={"X-Gotify-Key": token})
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)


    def label(message, names):
        appid = int(message.get("appid") or 0)
        return names.get(appid) or ("app %s" % appid)


    def format_batch(messages, names):
        if len(messages) == 1:
            message = messages[0]
            priority = message.get("priority") or 0
            mark = "🚨" if priority >= 8 else "🔔"
            title = (message.get("title") or "").strip() or "(sans titre)"
            head = "%s Gotify · %s — %s" % (mark, label(message, names), title)
            body = (message.get("message") or "").strip()
            return head + "\n" + body if body else head
        lines = ["🔔 Gotify · %d notifications" % len(messages)]
        for message in messages:
            priority = message.get("priority") or 0
            mark = "🚨" if priority >= 8 else "·"
            title = (message.get("title") or "").strip() or "(sans titre)"
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
            log("envoi Matrix impossible : %s" % exc)
            return False
        if result.returncode != 0:
            log("hermes send exit=%d stderr=%s" % (result.returncode, result.stderr.strip()[:300]))
            return False
        log("envoye dans Matrix (%d caracteres)" % len(text))
        return True


    def main():
        log("demarrage : API=%s salle=%s" % (API, ROOM))
        names = app_names()
        since = read_state()
        if since is None:
            # Premier demarrage : on n'inonde pas la salle avec l'historique,
            # on part du dernier message connu de Gotify.
            while True:
                if not os.path.exists(token_path()):
                    log("jeton client absent (%s) : pont inactif, nouvelle tentative dans 60s"
                        % token_path())
                    time.sleep(60)
                    continue
                try:
                    since = max([int(item["id"]) for item in fetch(read_token(), 0)] or [0])
                    break
                except Exception as exc:
                    log("amorcage impossible (%s), nouvel essai dans %ds" % (exc, POLL))
                    time.sleep(POLL)
            write_state(since)
            log("amorcage : depart au message #%d (historique ignore)" % since)
        cycles = 0
        while True:
            cycles += 1
            if cycles % 60 == 0:
                names = app_names()
            if not os.path.exists(token_path()):
                log("jeton client absent (%s) : pont inactif, nouvelle tentative dans 60s"
                    % token_path())
                time.sleep(60)
                continue
            try:
                batch = fetch(read_token(), since)
            except Exception as exc:
                log("lecture Gotify en echec (%s), nouvel essai dans %ds" % (exc, POLL))
                time.sleep(POLL)
                continue
            if batch:
                # regroupe la rafale : une seule connexion E2EE cote gateway
                time.sleep(BATCH)
                try:
                    batch += fetch(read_token(), max(int(item["id"]) for item in batch))
                except Exception:
                    pass
                batch.sort(key=lambda item: int(item["id"]))
                if deliver(format_batch(batch, names)):
                    since = max(int(item["id"]) for item in batch)
                    write_state(since)
                else:
                    log("envoi en echec : nouvelle tentative au prochain tour")
            time.sleep(POLL)


    if __name__ == "__main__":
        main()
  '';

in {
  options.services.gotifyMatrix = {
    # Actif par import (convention du depot) : couper avec
    # `services.gotifyMatrix.enable = false;` sur un hote qui importe
    # l'aggregateur sans vouloir le pont.
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Active le pont Gotify <-> Matrix (salle « 🪽 Hermes »).";
    };

    room = lib.mkOption {
      type = lib.types.str;
      default = "!bHIbXBYEcLDiMFtbse:matrix.marcpartensky.com";
      description = "Salle Matrix du pont (chiffree ; @marc + @hermes).";
    };

    gotifyUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8070";
      description = "API Gotify locale (le service bind 127.0.0.1).";
    };

    gotifyUser = lib.mkOption {
      type = lib.types.str;
      default = "marc@marcpartensky.com";
      description = "Compte Gotify admin pour l'auth basic de l'API (renomme au rattachement OIDC).";
    };

    clientName = lib.mkOption {
      type = lib.types.str;
      default = "hermes-matrix-relay";
      description = "Nom du client Gotify (jeton de lecture) cree par le provisionnement.";
    };

    applicationName = lib.mkOption {
      type = lib.types.str;
      default = "hermes-matrix-pont";
      description = "Nom de l'application Gotify (jeton de poussee) cree par le provisionnement.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/gotify-pont";
      description = "Repertoire des jetons provisionnes (root, jetons en 0400 hermes).";
    };

    pollSeconds = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Intervalle de lecture de la file Gotify.";
    };

    batchSeconds = lib.mkOption {
      type = lib.types.float;
      default = 3.0;
      description = "Fenetre de regroupement d'une rafale de notifications (un seul envoi Matrix).";
    };
  };

  config = lib.mkIf (cfg.enable && config.services.gotify.enable) {
    # Mot de passe LOCAL du compte admin Gotify (fichier sops dedie, chiffre
    # vers tower seulement). Il ne sert qu'a l'automatisation : marc se connecte
    # en OIDC (Zitadel). L'unite gotify-pont-provision (root) l'utilise pour
    # creer les jetons, et ALIGNE le hash bcrypt de la base si le mot de passe
    # historique n'est plus connu — meme patron que gotify-db-password, qui
    # aligne deja le role postgres de la meme base sur un secret sops.
    # (Le secret `gotify/admin_password` de tower.yml reste en place pour
    # GOTIFY_DEFAULTUSER_PASS, qui ne sert qu'a la creation d'une base neuve :
    # il ne correspond plus au mot de passe courant, c'est constate en 11/2026.)
    sops.secrets."gotify-matrix/admin_password" = {
      sopsFile = ../../secrets/gotify-matrix.yml;
      key = "admin_password";
    };

    # --- jetons Gotify (application + client), provisionnes en root ---
    # Un oneshot root : il lit le mot de passe admin (sops, root-only) et parle
    # a l'API locale. Idempotent : il reutilise les jetons deja presents.
    systemd.services.gotify-pont-provision = {
      description = "Provisionne les jetons Gotify du pont Matrix (application + client)";
      wantedBy = ["multi-user.target"];
      after = ["gotify-server.service"];
      requires = ["gotify-server.service"];
      before = ["gotify-matrix-relay.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = provision;
      };
    };

    # --- relais Gotify -> Matrix ---
    systemd.services.gotify-matrix-relay = {
      description = "Relais Gotify -> salle Matrix « Hermes » (hermes send)";
      wantedBy = ["multi-user.target"];
      after = ["gotify-pont-provision.service" "matrix-synapse.service"];
      wants = ["gotify-pont-provision.service"];
      requires = ["gotify-pont-provision.service"];
      serviceConfig = {
        User = "hermes";
        Group = "hermes";
        ExecStart = "${relay}/bin/gotify-matrix-relay";
        # jamais de sortie volontaire : on relance si le process meurt
        Restart = "always";
        RestartSec = 10;
        # Etat du curseur `since` (le process ecrit un fichier) : repertoire
        # possede par hermes, distinct de /var/lib/gotify-pont (root).
        StateDirectory = "gotify-matrix-relay";
        StateDirectoryMode = "0750";
        # `hermes send` a besoin de son home (token, appareil E2EE, state.db) :
        # pas de ProtectHome ni de ProtectSystem durci ici.
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
