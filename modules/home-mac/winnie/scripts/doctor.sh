# winnie-doctor : état du poste Mac pour builder Winnie.
#   winnie-doctor        diagnostic seul
#   winnie-doctor --fix  répare ce qui est automatisable (dépôt, node_modules,
#                        developer dir Xcode, licence, runtime du simulateur)
#
# Xcode, le SDK iOS et les runtimes du simulateur viennent d'Apple, jamais du
# store Nix : ce script est la seule source de vérité sur leur disponibilité.
repo="$HOME/@REPO_REL@"
api="@API_URL@"
sync_bin="@WINNIE_SYNC@"

fix=0
if [ "${1:-}" = "--fix" ]; then
  fix=1
fi

todo=0
line() { printf '%-8s %s\n' "$1" "$2"; }
ok() { line "[ok]" "$1"; }
missing() { line "[manque]" "$1"; todo=$((todo + 1)); }
info() { line "[-]" "$1"; }

printf 'winnie-doctor\n\n'

# --- nix ---------------------------------------------------------------
if command -v nix >/dev/null 2>&1; then
  ok "nix : $(nix --version)"
else
  missing "nix absent du PATH"
fi

# --- dépôt winnie ------------------------------------------------------
if [ -f "$repo/flake.nix" ]; then
  ok "dépôt : $repo"
  if nix --extra-experimental-features 'nix-command flakes' flake metadata "$repo" >/dev/null 2>&1; then
    ok "flake winnie évaluable"
  else
    missing "flake winnie non évaluable (nix flake metadata $repo)"
  fi
else
  missing "dépôt : $repo"
  if [ "$fix" = 1 ]; then
    echo "  -> winnie-sync"
    "$sync_bin" || true
  fi
fi

# --- Xcode : seul le build iOS l'exige ---------------------------------
xcode_ok=0
if [ -d /Applications/Xcode.app ]; then
  ok "Xcode.app installé"
  xcode_ok=1
else
  missing "Xcode.app absent (App Store, recherche « Xcode », ~8 Go)"
  info "sans Xcode : le front et le build macOS marchent, seul winnie-ios l'exige"
  info "fiche App Store : open 'macappstore://apps.apple.com/app/id497799835'"
fi

if [ -x /usr/bin/xcode-select ]; then
  devdir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [ "$devdir" = "/Applications/Xcode.app/Contents/Developer" ]; then
    ok "xcode-select : Xcode"
  elif [ "$xcode_ok" = 1 ]; then
    missing "xcode-select : ${devdir:-vide} (attendu /Applications/Xcode.app/Contents/Developer)"
    if [ "$fix" = 1 ]; then
      echo "  -> sudo xcode-select -s /Applications/Xcode.app (mot de passe macOS demandé)"
      sudo /usr/bin/xcode-select -s /Applications/Xcode.app
      sudo /usr/bin/xcodebuild -license accept || true
      /usr/bin/xcodebuild -runFirstLaunch || true
    fi
  else
    info "xcode-select : ${devdir:-vide} (Command Line Tools, suffisant hors iOS)"
  fi
else
  info "xcode-select absent (poste non macOS ?)"
fi

if [ "$xcode_ok" = 1 ]; then
  sdk="$(/usr/bin/xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
  if [ -n "$sdk" ]; then
    ok "SDK iOS : $sdk"
  else
    missing "SDK iOS (xcrun --sdk iphoneos --show-sdk-version ; licence Xcode non acceptée ?)"
    if [ "$fix" = 1 ]; then
      echo "  -> sudo xcodebuild -license accept"
      sudo /usr/bin/xcodebuild -license accept || true
    fi
  fi

  runtime_ok=0
  if /usr/bin/xcrun simctl list runtimes 2>/dev/null | grep -q 'iOS '; then
    runtime_ok=1
  fi
  if [ "$runtime_ok" = 1 ]; then
    ok "runtime du simulateur iOS"
  else
    missing "runtime du simulateur iOS"
    if [ "$fix" = 1 ]; then
      echo "  -> xcodebuild -downloadPlatform iOS (~8 Go, plusieurs minutes)"
      /usr/bin/xcodebuild -downloadPlatform iOS || true
    fi
  fi
fi

# --- front / node ------------------------------------------------------
if [ -f "$repo/app/package.json" ]; then
  if [ -d "$repo/app/node_modules" ]; then
    ok "app/node_modules (npm ci fait)"
  else
    missing "app/node_modules"
    if [ "$fix" = 1 ]; then
      echo "  -> npm ci dans le devShell (~1 min)"
      (cd "$repo" && nix --extra-experimental-features 'nix-command flakes' develop -c bash -c "cd app && npm ci") || true
    fi
  fi
  if [ -d "$repo/app/src-tauri/gen/apple" ]; then
    ok "projet Xcode généré (src-tauri/gen/apple)"
  else
    info "src-tauri/gen/apple absent : winnie-ios le génère (tauri ios init)"
  fi
fi

# --- API ---------------------------------------------------------------
code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$api/healthz" 2>/dev/null || true)"
if [ "$code" = "200" ]; then
  ok "API : $api"
else
  missing "API : $api/healthz (HTTP ${code:-aucune réponse})"
fi

# --- verdict -----------------------------------------------------------
printf '\n'
if [ "$todo" -eq 0 ]; then
  echo "tout est prêt : winnie-ios (simulateur), winnie-front, winnie-macos."
  exit 0
fi
echo "$todo contrôle(s) en échec."
if [ "$fix" = 1 ]; then
  echo "relance winnie-doctor pour vérifier ce qui reste."
else
  echo "winnie-doctor --fix répare ce qui est automatisable."
fi
exit 1
