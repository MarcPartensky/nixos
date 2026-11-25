# Vite (HMR) server of app/: reachable on the LAN (http://<mac>:8080) and on
# dev.winnie.marcpartensky.com via Pangolin. Launched by winnie-front, so the
# tools (node 22, npm) come from the winnie flake's devShell.
repo="$HOME/@REPO_REL@"
cd "$repo/app"

if [ ! -d node_modules ]; then
  echo "[winnie-front] npm ci"
  npm ci
fi

exec npm run dev "$@"
