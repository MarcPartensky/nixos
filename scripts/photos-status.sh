#!/usr/bin/env bash
# scripts/photos-status.sh
# Etat du pipeline photos : ce qui est sur le tel (si adb le voit), ce qui est
# dans l'arbre local, ce qui est dans Garage, et l'etat du miroir automatique.
set -uo pipefail

# Groupe `photos` (marc + hermes, 2770 setgid) : une session hermes ouverte avant
# sa creation ne le voit pas dans ses groupes supplementaires, donc re-execution
# via sg pour pouvoir lire l'arbre.
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

echo "=== arbre local ($ROOT) ==="
if [ -d "$ROOT" ]; then
  for src in "${!BUCKETS[@]}"; do
    if [ -d "$ROOT/$src" ]; then
      printf '  %-10s %6s fichiers  %8s\n' "$src" \
        "$(find "$ROOT/$src" -type f 2>/dev/null | wc -l)" \
        "$(du -sh "$ROOT/$src" 2>/dev/null | cut -f1)"
    else
      printf '  %-10s (absent)\n' "$src"
    fi
  done
else
  echo "  $ROOT absent (activation passee ?)"
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
    # rclone size sort de l'humain ("Total objects: 12 (12)" et "Total size:
    # 1.2 MiB (1234567 Byte)") : on affiche tel quel, pas de parsing JSON donc
    # pas de cas particulier quand un bucket est vide.
    if out=$(rclone size "garage:${BUCKETS[$src]}" 2>/dev/null); then
      printf '  %-10s %s\n' "$src" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"
    else
      printf '  %-10s (bucket injoignable)\n' "$src"
    fi
  done
else
  echo "  identifiants Garage illisibles ($CREDS)"
fi

echo "=== capacite ==="
if command -v zfs >/dev/null 2>&1; then
  zfs get -H -o property,value quota,used "$DATASET" 2>/dev/null | sed 's/^/  /' || echo "  $DATASET illisible"
fi
df -h /home/marc 2>/dev/null | tail -1 | sed 's/^/  /'

echo "=== miroir automatique ==="
systemctl is-active photos-to-garage.timer 2>/dev/null | sed 's/^/  timer: /'
systemctl list-timers photos-to-garage.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/  /'
