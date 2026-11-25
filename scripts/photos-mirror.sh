#!/usr/bin/env bash
# scripts/photos-mirror.sh
# Push the local photos tree to Garage (one bucket per source). Same work
# as the photos-to-garage systemd timer, but runnable by hermes right after an
# adb pull, without waiting for the next hour.
#
# Garage is a MIRROR: the source of truth remains /home/marc/media/photos
# (ZFS dataset). An S3 failure loses nothing, it delays the copy.
set -euo pipefail

# `photos` group (marc + hermes, 2770 setgid): a hermes session opened before
# its creation does not have it in its groups, so re-execution via sg.
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

[ -r "$CREDS" ] || { echo "Garage credentials unreadable: $CREDS" >&2; exit 1; }
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
  [ -d "$dir" ] || { echo "$src: no local directory, skipped"; continue; }
  echo "=== $src -> garage:${BUCKETS[$src]} ==="
  # .pulled: resume markers from photos-pull.sh, never to be pushed.
  rclone sync "$dir" "garage:${BUCKETS[$src]}" \
    --transfers 4 --checkers 8 \
    --exclude '.pulled/**' --exclude '.stfolder/**' \
    --exclude '.thumbnails/**' --exclude '*.tmp' --exclude '.nomedia' \
    --stats-one-line --stats 30s \
    || { echo "$src: mirror failed" >&2; rc=1; }
done
exit $rc
