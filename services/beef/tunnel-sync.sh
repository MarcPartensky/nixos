#!/usr/bin/env bash
# Realigne BeEF sur le nom courant du tunnel rapide.
#
# Un tunnel rapide Cloudflare prend un nom aleatoire a chaque demarrage, et
# beef.http.public.host doit suivre. Plutot qu'un chemin d'evenement (le log du
# tunnel bouge en permanence), on compare periodiquement le nom courant a celui
# que BeEF a rendu : s'ils divergent, on redemarre beef, dont l'ExecStartPre
# regenere la config.
set -euo pipefail

: "${BEEF_STATE_DIR:?BEEF_STATE_DIR manquant}"

log="$BEEF_STATE_DIR/cloudflared.log"
current=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" 2>/dev/null | tail -1 | sed 's|^https://||' || true)

if [ -z "$current" ]; then
  exit 0
fi

rendered=$(cat "$BEEF_STATE_DIR/public-host" 2>/dev/null || true)

if [ "$current" != "$rendered" ]; then
  echo "tunnel renomme ($rendered -> $current) : redemarrage de beef"
  systemctl restart beef.service
fi
