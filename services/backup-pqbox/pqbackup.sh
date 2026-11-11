#!/bin/sh
# pqbackup.sh : sauvegardes chiffrées pqbox de tower, en trois étages.
#
#   pqbackup.sh coeur    bases vivantes + état Hermes léger   (quotidien, zstd -19 --long)
#   pqbackup.sh volume   winnie, matrix-synapse, state.db, pièces jointes (hebdo, zstd -3)
#   pqbackup.sh mortes   bases abandonnées, une fois pour toutes (zstd -12)
#   pqbackup.sh all      les trois à la suite
#
# Options : --keep N (rétention par étage), --dest DIR, --no-rack (ne pas copier)
#
# Le chiffrement se fait vers backup.pub : la clé privée et le mot de passe de
# marc ne sont pas nécessaires ici, seul lui peut relire les archives.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PUB=${PUB:-$HERE/backup.pub}
PQBOX=${PQBOX:-$HERE/pqbox}
PG="psql -h 127.0.0.1 -U root"
PGD="pg_dump -h 127.0.0.1 -U root -Fp --clean --if-exists"

OUTDIR=${OUTDIR:-/var/lib/hermes/backups/pqbox}
RACK=${RACK:-rack:/var/backups/pqbox}
HERMES=/var/lib/hermes/.hermes
KEEP_COEUR=${KEEP_COEUR:-30}   # rétention par étage (surchargeable par le module NixOS)
KEEP_VOLUME=${KEEP_VOLUME:-3}
KEEP_MORTES=${KEEP_MORTES:-2}
NO_RACK=0

COEUR_DBS="nextcloud ffsync taskq postgres zitadel gitea vaultwarden windmill gotify hermes music website resume reactive-resume shlink"
VOLUME_DBS="winnie matrix-synapse"
VOLUME_HERMES="state.db attachments"
MORTES_DBS="root wger matrix wallabag focalboard authentik etherpad matrix_whatsapp matrix_signal matrix_messenger matrix_slack matrix_facebook matrix_twitter matrix_gmessages matrix_meta matrix_discord nocodb appflowy invidious n8n outline strapi homeassistant etesync peertube grafana paperless udemy kutt heimdall dockerdash djankiserv mailu izitdone lorimer_eats rentscout gotrue fdroid linkwarden docuseal tokenserver syncstorage owncloud yourls wikijs bookstack template1"

tier=""
for a in "$@"; do
  case "$a" in
    --keep=*) KEEP_COEUR=${a#*=}; KEEP_VOLUME=$KEEP_COEUR; KEEP_MORTES=$KEEP_COEUR;;
    --dest=*) OUTDIR=${a#*=};;
    --no-rack) NO_RACK=1;;
    coeur|volume|mortes|all) tier="$a";;
  esac
done
[ -n "$tier" ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ -f "$PUB" ] || { echo "clé publique absente: $PUB" >&2; exit 1; }

stamp=$(date +%Y-%m-%dT%H%M)

manifest_header() {
  echo "pqbox $1"
  echo "date: $(date -Is)"
  echo "host: $(hostname)"
  echo "postgres: $($PG -d postgres -tAc 'select version()')"
  echo "chiffrement: ML-KEM-768 + X25519, HKDF-SHA256, AES-256-GCM (pqbox 1.0.0)"
  echo "compression: $2"
  echo
}

# dump_db <db> <dir> : dump d'une base + empreinte
dump_db() {
  _db=$1; _dir=$2
  if ! $PGD -f "$_dir/$_db.sql" "$_db" 2>"$_dir/$_db.err"; then
    echo "  !! dump de $_db en echec:"; cat "$_dir/$_db.err"; return 1
  fi
  rm -f "$_dir/$_db.err"
  echo "  $_db $(du -h --apparent-size "$_dir/$_db.sql" | cut -f1)"
}

# build_and_ship <etage> <stage> <niveau zstd> <retention>
build_and_ship() {
  _tier=$1; _stage=$2; _zstd=$3; _keep=$4
  ( cd "$_stage" && sha256sum ./* 2>/dev/null ) > "$_stage/MANIFEST.hashes"
  {
    manifest_header "$_tier" "$_zstd"
    echo "## fichiers (brut, sha256)"
    cat "$_stage/MANIFEST.hashes"
  } > "$_stage/MANIFEST.txt"
  rm -f "$_stage/MANIFEST.hashes"
  tar -C "$_stage" -cf - . | zstd ${_zstd} -q -o "$WORK/payload.zst"
  zstd -t "$WORK/payload.zst" >/dev/null
  "$PQBOX" encrypt --recipient "$PUB" --in "$WORK/payload.zst" --out "$WORK/archive.pqbox"
  out="$OUTDIR/$_tier-$stamp.pqbox"
  mv "$WORK/archive.pqbox" "$out"
  chmod 0644 "$out"
  ( cd "$OUTDIR" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
  echo "  -> $out ($(du -h --apparent-size "$out" | cut -f1))"
  echo "     sha256 $(cut -d' ' -f1 "$out.sha256")"
  if [ "$NO_RACK" = 0 ]; then
    if scp -q -o BatchMode=yes "$out" "$out.sha256" "$RACK/"; then
      echo "     copié sur $RACK"
      if ssh -o BatchMode=yes "${RACK%%:*}" "cd '${RACK#*:}' && sha256sum -c '$(basename "$out").sha256'" >/dev/null 2>&1; then
        echo "     sha256 distant vérifié"
      else
        echo "     !! vérification distante impossible"
      fi
    else
      echo "     !! copie vers $RACK impossible"
    fi
  fi
  # rétention sur les archives locales puis distantes
  ls -1t "$OUTDIR"/$_tier-*.pqbox 2>/dev/null | tail -n +$((_keep + 1)) | while read -r old; do
    echo "     rétention: suppression de $(basename "$old")"
    rm -f "$old" "$old.sha256"
    [ "$NO_RACK" = 0 ] && ssh -o BatchMode=yes "${RACK%%:*}" "rm -f '${RACK#*:}/$(basename "$old")' '${RACK#*:}/$(basename "$old").sha256'" >/dev/null 2>&1 || true
  done
}

do_coeur() {
  echo "[coeur] bases vivantes + état Hermes léger"
  stage="$WORK/stage"; mkdir -p "$stage"
  for db in $COEUR_DBS; do dump_db "$db" "$stage" || true; done
  $PG -d postgres -tAc "select rolname, rolcanlogin, rolsuper from pg_roles order by 1" > "$stage/roles.txt"
  $PG -d postgres -c "select datname, pg_size_pretty(pg_database_size(datname)) as taille, pg_database_size(datname) as octets from pg_database order by octets desc" > "$stage/bases.txt"
  tar -C "$HERMES" -cf "$stage/hermes-etat.tar" \
    config.yaml auth.json credentials cron skills sessions plugins profiles 2>/dev/null
  build_and_ship coeur "$stage" "-19 --long=27 -T8" "$KEEP_COEUR"
}

do_volume() {
  echo "[volume] winnie, matrix-synapse, state.db, pièces jointes"
  stage="$WORK/stage"; mkdir -p "$stage"
  for db in $VOLUME_DBS; do dump_db "$db" "$stage" || true; done
  tar -C "$HERMES" -cf "$stage/hermes-lourd.tar" $VOLUME_HERMES 2>/dev/null
  build_and_ship volume "$stage" "-3 -T16" "$KEEP_VOLUME"
}

do_mortes() {
  echo "[mortes] bases abandonnées (archive unique)"
  stage="$WORK/stage"; mkdir -p "$stage"
  for db in $MORTES_DBS; do dump_db "$db" "$stage" || true; done
  build_and_ship mortes "$stage" "-12 -T16" "$KEEP_MORTES"
}

run_tier() {
  WORK="$OUTDIR/.work-$1-$stamp"
  mkdir -p "$WORK"
  trap 'rm -rf "$WORK"' EXIT INT TERM
  case "$1" in
    coeur) do_coeur;;
    volume) do_volume;;
    mortes) do_mortes;;
  esac
  rm -rf "$WORK"
  trap - EXIT INT TERM
}

mkdir -p "$OUTDIR"
case "$tier" in
  coeur) run_tier coeur;;
  volume) run_tier volume;;
  mortes) run_tier mortes;;
  all) run_tier coeur; run_tier volume; run_tier mortes;;
esac
echo "terminé: $(date -Is)"
