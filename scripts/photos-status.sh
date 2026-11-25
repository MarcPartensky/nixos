#!/usr/bin/env bash
# scripts/photos-status.sh
# Photos pipeline state: what is on the phone (if adb sees it), what is
# in the local tree, what is in Garage, and the state of the automatic mirror.
set -uo pipefail

# `photos` group (marc + hermes, 2770 setgid): a hermes session opened before
# its creation does not see it in its supplementary groups, so re-execution
# via sg to be able to read the tree.
if ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx photos; then
  exec sg photos -c "$(printf '%q ' "$0" "$@")"
fi

ROOT=${PHOTOS_ROOT:-/home/marc/media/photos}
CREDS=${GARAGE_KEY_FILE:-/var/lib/garage/s3-key.env}
DATASET=${PHOTOS_DATASET:-nixos/marc/media}

declare -A BUCKETS=(
  [camera]=photos-camera
  [whatsapp]=photos-whatsapp
  [messenger]=photos-messenger
)

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1"; }

echo "=== local tree ($ROOT) ==="
if [ -d "$ROOT" ]; then
  for src in "${!BUCKETS[@]}"; do
    if [ -d "$ROOT/$src" ]; then
      printf '  %-10s %6s files  %8s\n' "$src" \
        "$(find "$ROOT/$src" -type f 2>/dev/null | wc -l)" \
        "$(du -sh "$ROOT/$src" 2>/dev/null | cut -f1)"
    else
      printf '  %-10s (absent)\n' "$src"
    fi
  done
else
  echo "  $ROOT absent (activation passed?)"
fi

echo "=== Garage ==="
if [ -r "$CREDS" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$CREDS"
  set +a
  export RCLONE_CONFIG_GARAGE_TYPE=s3 RCLONE_CONFIG_GARAGE_PROVIDER=Other \
    RCLONE_CONFIG_GARAGE_ENDPOINT=http://127.0.0.1:3900 \
    RCLONE_CONFIG_GARAGE_REGION=garage \
    RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
  for src in "${!BUCKETS[@]}"; do
    # rclone size outputs human ("Total objects: 12 (12)" and "Total size:
    # 1.2 MiB (1234567 Byte)"): we display it as-is, no JSON parsing so
    # no special case when a bucket is empty.
    if out=$(rclone size "garage:${BUCKETS[$src]}" 2>/dev/null); then
      printf '  %-10s %s\n' "$src" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"
    else
      printf '  %-10s (bucket unreachable)\n' "$src"
    fi
  done
else
  echo "  Garage credentials unreadable ($CREDS)"
fi

echo "=== capacity ==="
if command -v zfs >/dev/null 2>&1; then
  zfs get -H -o property,value quota,used "$DATASET" 2>/dev/null | sed 's/^/  /' || echo "  $DATASET unreadable"
fi
df -h /home/marc 2>/dev/null | tail -1 | sed 's/^/  /'

echo "=== automatic mirror ==="
systemctl is-active photos-to-garage.timer 2>/dev/null | sed 's/^/  timer: /'
systemctl list-timers photos-to-garage.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/  /'
