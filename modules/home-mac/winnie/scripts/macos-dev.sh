# macOS app (Tauri window + Vite in HMR): neither Xcode nor a simulator,
# Command Line Tools are enough.
repo="$HOME/@REPO_REL@"
cd "$repo/app"

if [ ! -d node_modules ]; then
  echo "[winnie-macos] npm ci"
  npm ci
fi

exec ./node_modules/.bin/tauri dev "$@"
