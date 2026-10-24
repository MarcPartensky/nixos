# Serveur Vite (HMR) de app/ : joignable sur le LAN (http://<mac>:8080) et sur
# dev.winnie.marcpartensky.com via Pangolin. Lancé par winnie-front, donc les
# outils (node 22, npm) viennent du devShell du flake winnie.
repo="$HOME/@REPO_REL@"
cd "$repo/app"

if [ ! -d node_modules ]; then
  echo "[winnie-front] npm ci"
  npm ci
fi

exec npm run dev "$@"
