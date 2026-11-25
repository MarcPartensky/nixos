# winnie-sync: refreshes ~/git/winnie from tower, the source of truth
# (the repo has no git remote: tower is the only original).
# The first ssh alias that answers wins: LAN first (towerlocal), then the
# tunnel through the VPS (tower -> 10.100.0.3 via rack, kept up by the autossh agent).
#   winnie-sync            incremental copy, keeps extra local files
#   winnie-sync --delete   strict mirror of tower (deletes extra files)
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
  echo "unreachable"
done

if [ -z "$host" ]; then
  echo "winnie-sync: tower unreachable (tried: ${hosts[*]})" >&2
  echo "winnie-sync: LAN = towerlocal (192.168.1.44); off LAN = tower (via rack)" >&2
  exit 1
fi

mkdir -p "$repo"
echo "winnie-sync : $host:$tower_repo -> $repo"

# Progress bar only on a terminal (otherwise a redirected
# log fills up with carriage returns).
progress=()
if [ -t 1 ]; then
  progress=(--info=progress2)
fi

# What never crosses over: per-platform binaries (node_modules, tauri-cli)
# and machine-bound artifacts (target, generated Xcode project, signing keys).
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

echo "winnie-sync: done (winnie-doctor for the machine state)."
