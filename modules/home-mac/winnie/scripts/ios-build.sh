# iOS archive for a real iPhone (and IPA export if an Apple account is
# configured in Xcode). The simulator requires no account, not this.
repo="$HOME/@REPO_REL@"
cd "$repo/app"

if [ ! -d node_modules ]; then
  echo "[winnie-build-ios] npm ci"
  npm ci
fi

if [ ! -d src-tauri/gen/apple ]; then
  echo "[winnie-build-ios] tauri ios init (Xcode project + pod install)"
  ./node_modules/.bin/tauri ios init
fi

exec ./node_modules/.bin/tauri ios build --target aarch64 "$@"
