# winnie-doctor: state of the Mac workstation for building Winnie.
#   winnie-doctor        diagnostic only
#   winnie-doctor --fix  repairs what is automatable (repo, node_modules,
#                        Xcode developer dir, license, simulator runtime)
#
# Xcode, the iOS SDK and the simulator runtimes come from Apple, never from the
# Nix store: this script is the single source of truth on their availability.
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
missing() { line "[missing]" "$1"; todo=$((todo + 1)); }
info() { line "[-]" "$1"; }

printf 'winnie-doctor\n\n'

# --- nix ---------------------------------------------------------------
if command -v nix >/dev/null 2>&1; then
  ok "nix : $(nix --version)"
else
  missing "nix absent from PATH"
fi

# --- winnie repo -------------------------------------------------------
if [ -f "$repo/flake.nix" ]; then
  ok "repo: $repo"
  if nix --extra-experimental-features 'nix-command flakes' flake metadata "$repo" >/dev/null 2>&1; then
    ok "winnie flake evaluable"
  else
    missing "winnie flake not evaluable (nix flake metadata $repo)"
  fi
else
  missing "repo: $repo"
  if [ "$fix" = 1 ]; then
    echo "  -> winnie-sync"
    "$sync_bin" || true
  fi
fi

# --- Xcode: only the iOS build requires it -----------------------------
xcode_ok=0
if [ -d /Applications/Xcode.app ]; then
  ok "Xcode.app installed"
  xcode_ok=1
else
  missing "Xcode.app absent (App Store, search Xcode, ~8 GB)"
  info "without Xcode: the front and the macOS build work, only winnie-ios requires it"
  info "App Store page: open 'macappstore://apps.apple.com/app/id497799835'"
fi

if [ -x /usr/bin/xcode-select ]; then
  devdir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [ "$devdir" = "/Applications/Xcode.app/Contents/Developer" ]; then
    ok "xcode-select : Xcode"
  elif [ "$xcode_ok" = 1 ]; then
    missing "xcode-select: ${devdir:-empty} (expected /Applications/Xcode.app/Contents/Developer)"
    if [ "$fix" = 1 ]; then
      echo "  -> sudo xcode-select -s /Applications/Xcode.app (macOS password requested)"
      sudo /usr/bin/xcode-select -s /Applications/Xcode.app
      sudo /usr/bin/xcodebuild -license accept || true
      /usr/bin/xcodebuild -runFirstLaunch || true
    fi
  else
    info "xcode-select: ${devdir:-empty} (Command Line Tools, enough outside iOS)"
  fi
else
  info "xcode-select absent (non-macOS machine?)"
fi

if [ "$xcode_ok" = 1 ]; then
  sdk="$(/usr/bin/xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
  if [ -n "$sdk" ]; then
    ok "SDK iOS : $sdk"
  else
    missing "iOS SDK (xcrun --sdk iphoneos --show-sdk-version; Xcode license not accepted?)"
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
    ok "iOS simulator runtime"
  else
    missing "iOS simulator runtime"
    if [ "$fix" = 1 ]; then
      echo "  -> xcodebuild -downloadPlatform iOS (~8 GB, several minutes)"
      /usr/bin/xcodebuild -downloadPlatform iOS || true
    fi
  fi
fi

# --- front / node ------------------------------------------------------
if [ -f "$repo/app/package.json" ]; then
  if [ -d "$repo/app/node_modules" ]; then
    ok "app/node_modules (npm ci done)"
  else
    missing "app/node_modules"
    if [ "$fix" = 1 ]; then
      echo "  -> npm ci in the devShell (~1 min)"
      (cd "$repo" && nix --extra-experimental-features 'nix-command flakes' develop -c bash -c "cd app && npm ci") || true
    fi
  fi
  if [ -d "$repo/app/src-tauri/gen/apple" ]; then
    ok "generated Xcode project (src-tauri/gen/apple)"
  else
    info "src-tauri/gen/apple absent: winnie-ios generates it (tauri ios init)"
  fi
fi

# --- API ---------------------------------------------------------------
code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$api/healthz" 2>/dev/null || true)"
if [ "$code" = "200" ]; then
  ok "API : $api"
else
  missing "API: $api/healthz (HTTP ${code:-no response})"
fi

# --- verdict -----------------------------------------------------------
printf '\n'
if [ "$todo" -eq 0 ]; then
  echo "everything is ready: winnie-ios (simulator), winnie-front, winnie-macos."
  exit 0
fi
echo "$todo check(s) failing."
if [ "$fix" = 1 ]; then
  echo "rerun winnie-doctor to check what remains."
else
  echo "winnie-doctor --fix repairs what is automatable."
fi
exit 1
