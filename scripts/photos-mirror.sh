#!/usr/bin/env bash
# scripts/photos-mirror.sh
# Pousse l'arbre photos local vers Garage (un bucket par source). Meme travail
# que le timer systemd photos-to-garage, mais lancable par hermes juste apres un
# rapatriement adb, sans attendre l'heure suivante.
#
# Garage est un MIROIR : la source de verite reste /home/marc/media/photos
# (dataset ZFS). Un echec d'S3 ne perd rien, il retarde la copie.
set -euo pipefail

# Groupe `photos` (marc + hermes, 2770 setgid) : une session hermes ouverte avant
# sa creation ne l'a pas dans ses groupes, donc re-execution via sg.
if ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx photos; then
  exec sg photos -c "$(printf '%q ' "$0" "$@")"
fi

ROOT=${PHOTOS_ROOT:-/home/marc/media/photos}
CREDS=${GARAGE_KEY_FILE:-/var/lib/garage/s3-key.env}
ENDPOINT=${GARAGE_ENDPOINT:-http://127.0.0.1:3900}

declare -A BUCKETS=(
  [camera]=photos-camera
  [whatsapp]=photos-whatsapp
  [messenger]=photos-messenger
)

[ -r "$CREDS" ] || { echo "identifiants Garage illisibles : $CREDS" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$CREDS"
set +a

export RCLONE_CONFIG_GARAGE_TYPE=s3
export RCLONE_CONFIG_GARAGE_PROVIDER=Other
export RCLONE_CONFIG_GARAGE_ENDPOINT="$ENDPOINT"
export RCLONE_CONFIG_GARAGE_REGION=garage
export RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"

rc=0
for src in "${!BUCKETS[@]}"; do
  dir="$ROOT/$src"
  [ -d "$dir" ] || { echo "$src : pas de dossier local, ignore"; continue; }
  echo "=== $src -> garage:${BUCKETS[$src]} ==="
  # .pulled : marqueurs de reprise de photos-pull.sh, jamais a pousser.
  rclone sync "$dir" "garage:${BUCKETS[$src]}" \
    --transfers 4 --checkers 8 \
    --exclude '.pulled/**' --exclude '.stfolder/**' \
    --exclude '.thumbnails/**' --exclude '*.tmp' --exclude '.nomedia' \
    --stats-one-line --stats 30s \
    || { echo "$src : echec du miroir" >&2; rc=1; }
done
exit $rc
