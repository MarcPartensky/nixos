# Archive iOS pour un iPhone réel (et export IPA si un compte Apple est
# configuré dans Xcode). Le simulateur n'exige aucun compte, pas ceci.
repo="$HOME/@REPO_REL@"
cd "$repo/app"

if [ ! -d node_modules ]; then
  echo "[winnie-build-ios] npm ci"
  npm ci
fi

if [ ! -d src-tauri/gen/apple ]; then
  echo "[winnie-build-ios] tauri ios init (projet Xcode + pod install)"
  ./node_modules/.bin/tauri ios init
fi

exec ./node_modules/.bin/tauri ios build --target aarch64 "$@"
