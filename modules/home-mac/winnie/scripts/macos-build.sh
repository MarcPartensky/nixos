# Bundle macOS (.app + .dmg) : app/src-tauri/target/release/bundle/.
repo="$HOME/@REPO_REL@"
cd "$repo/app"

if [ ! -d node_modules ]; then
  echo "[winnie-build-macos] npm ci"
  npm ci
fi

exec ./node_modules/.bin/tauri build "$@"
