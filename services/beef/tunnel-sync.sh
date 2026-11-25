#!/usr/bin/env bash
# Realigns BeEF on the current name of the quick tunnel.
#
# A Cloudflare quick tunnel takes a random name on each start, and
# beef.http.public.host must follow. Rather than an event path (the tunnel
# log moves constantly), we periodically compare the current name with the one
# BeEF has rendered: if they diverge, we restart beef, whose ExecStartPre
# regenerates the config.
set -euo pipefail

: "${BEEF_STATE_DIR:?BEEF_STATE_DIR missing}"

log="$BEEF_STATE_DIR/cloudflared.log"
current=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" 2>/dev/null | tail -1 | sed 's|^https://||' || true)

if [ -z "$current" ]; then
  exit 0
fi

rendered=$(cat "$BEEF_STATE_DIR/public-host" 2>/dev/null || true)

if [ "$current" != "$rendered" ]; then
  echo "tunnel renamed ($rendered -> $current): restarting beef"
  systemctl restart beef.service
fi
