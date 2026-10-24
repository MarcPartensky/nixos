# App macOS (fenêtre Tauri + Vite en HMR) : ni Xcode ni simulateur, les
# Command Line Tools suffisent.
repo="$HOME/@REPO_REL@"
cd "$repo/app"

if [ ! -d node_modules ]; then
  echo "[winnie-macos] npm ci"
  npm ci
fi

exec ./node_modules/.bin/tauri dev "$@"
