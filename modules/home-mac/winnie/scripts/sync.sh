# winnie-sync : rafraîchit ~/git/winnie depuis tower, la source de vérité
# (le dépôt n'a pas de remote git : tower est le seul original).
# Le premier alias ssh qui répond gagne : LAN d'abord (towerlocal), puis le
# tunnel par le VPS (tower -> 10.100.0.3 via rack, tenu par l'agent autossh).
#   winnie-sync            copie incrémentale, garde les fichiers locaux en trop
#   winnie-sync --delete   miroir strict de tower (supprime les fichiers en trop)
repo="$HOME/@REPO_REL@"
tower_repo="@TOWER_REPO@"
hosts=(@TOWER_HOSTS@)

delete=()
if [ "${1:-}" = "--delete" ]; then
  delete=(--delete)
elif [ -n "${1:-}" ]; then
  echo "usage: winnie-sync [--delete]" >&2
  exit 2
fi

host=""
for h in "${hosts[@]}"; do
  printf 'winnie-sync : %s... ' "$h"
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$h" true >/dev/null 2>&1; then
    echo "ok"
    host="$h"
    break
  fi
  echo "injoignable"
done

if [ -z "$host" ]; then
  echo "winnie-sync : tower injoignable (essayé : ${hosts[*]})" >&2
  echo "winnie-sync : LAN = towerlocal (192.168.1.44) ; hors LAN = tower (via rack)" >&2
  exit 1
fi

mkdir -p "$repo"
echo "winnie-sync : $host:$tower_repo -> $repo"

# La barre de progression seulement sur un terminal (sans quoi un log
# redirigé se remplit de retours chariot).
progress=()
if [ -t 1 ]; then
  progress=(--info=progress2)
fi

# Ce qui ne traverse jamais : binaires par plateforme (node_modules, tauri-cli)
# et artefacts liés à la machine (target, projet Xcode généré, clés de signature).
rsync -a --no-owner --no-group "${progress[@]}" \
  --exclude /.direnv/ \
  --exclude /backend/target/ \
  --exclude /ingest/target/ \
  --exclude /app/node_modules/ \
  --exclude /app/dist/ \
  --exclude /app/src-tauri/target/ \
  --exclude /app/src-tauri/gen/ \
  --exclude /app/.android-sdk/ \
  --exclude /app/.android-user/ \
  --exclude /app/.keys/ \
  "${delete[@]}" \
  "$host:$tower_repo/" "$repo/"

echo "winnie-sync : terminé (winnie-doctor pour l'état du poste)."
