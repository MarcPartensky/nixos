# App iOS en dev : simulateur (aucun compte Apple requis) ou iPhone branché.
# npm ci et `tauri ios init` (projet Xcode + pod install) sont faits au besoin,
# donc la toute première exécution est longue.
#   winnie-ios                        premier iPhone du simulateur
#   winnie-ios "iPhone 17 Pro"        appareil précis, en argument positionnel
#   WINNIE_IOS_DEVICE=<nom|udid> winnie-ios
#   winnie-ios --force-ip-prompt      sur le LAN (Vite sert déjà le LAN)
# `tauri ios dev` prend l'appareil en positionnel (le champ `device` de la CLI
# n'a pas d'attribut clap) et ouvre un menu interactif quand on ne passe rien :
# d'où la recherche du premier iPhone pour que la commande marche seule.
repo="$HOME/@REPO_REL@"
cd "$repo/app"

if [ ! -d node_modules ]; then
  echo "[winnie-ios] npm ci"
  npm ci
fi

if [ ! -d src-tauri/gen/apple ]; then
  echo "[winnie-ios] tauri ios init (projet Xcode + pod install)"
  ./node_modules/.bin/tauri ios init
fi

args=("$@")
if [ "${#args[@]}" -eq 0 ] && [ -n "${WINNIE_IOS_DEVICE:-}" ]; then
  args=("$WINNIE_IOS_DEVICE")
fi

if [ "${#args[@]}" -eq 0 ]; then
  sim="$(xcrun simctl list devices available 2>/dev/null | awk -F ' \\(' '/^ *iPhone/ {sub(/^ */, "", $1); print $1; exit}' || true)"
  if [ -n "$sim" ]; then
    echo "[winnie-ios] simulateur : $sim"
    args=("$sim")
  fi
fi

exec ./node_modules/.bin/tauri ios dev "${args[@]}"
