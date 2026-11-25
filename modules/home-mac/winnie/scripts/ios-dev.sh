# iOS app in dev: simulator (no Apple account required) or plugged-in iPhone.
# npm ci and `tauri ios init` (Xcode project + pod install) are done as needed,
# so the very first run is long.
#   winnie-ios                        first simulator iPhone
#   winnie-ios "iPhone 17 Pro"        specific device, as a positional argument
#   WINNIE_IOS_DEVICE=<nom|udid> winnie-ios
#   winnie-ios --force-ip-prompt      on the LAN (Vite already serves the LAN)
# `tauri ios dev` takes the device as a positional (the CLI's `device` field
# has no clap attribute) and opens an interactive menu when nothing is passed:
# hence the search for the first iPhone so the command works on its own.
repo="$HOME/@REPO_REL@"
cd "$repo/app"

if [ ! -d node_modules ]; then
  echo "[winnie-ios] npm ci"
  npm ci
fi

if [ ! -d src-tauri/gen/apple ]; then
  echo "[winnie-ios] tauri ios init (Xcode project + pod install)"
  ./node_modules/.bin/tauri ios init
fi

args=("$@")
if [ "${#args[@]}" -eq 0 ] && [ -n "${WINNIE_IOS_DEVICE:-}" ]; then
  args=("$WINNIE_IOS_DEVICE")
fi

if [ "${#args[@]}" -eq 0 ]; then
  sim="$(xcrun simctl list devices available 2>/dev/null | awk -F ' \\(' '/^ *iPhone/ {sub(/^ */, "", $1); print $1; exit}' || true)"
  if [ -n "$sim" ]; then
    echo "[winnie-ios] simulator: $sim"
    args=("$sim")
  fi
fi

exec ./node_modules/.bin/tauri ios dev "${args[@]}"
