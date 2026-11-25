#!/bin/sh
# nod-bootstrap.sh: provisions (or repairs) an Android Nix-on-Droid device
# for remote and long-duration control by marc's agent.
#
# On the device, in the terminal of the Nix-on-Droid app (com.termux.nix):
#   curl -fsSL <short-link> | sh                 # installs / updates / repairs
#   curl -fsSL <short-link> | sh -s status       # state only, touches nothing
#
# Also works once already installed, for a maintenance switch:
#   /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/nod-bootstrap
#
# Variables (all optional):
#   NOD_FLAKE     flake to deploy             (default github:MarcPartensky/nixos)
#   NOD_DEVICE    configuration attribute     (default: `default`)
#   NOD_RELAY_KEY ed25519 relay key in base64, written to ~/.ssh/relay_ed25519
#                 (without it, the device stays reachable via ssh on the LAN, :8023)
#   NOD_NO_SWITCH 1 = do not relaunch the switch (verification only)
#
# No secret is contained in this script: it is only there to make
# the device declarative, reproducible and repairable in one command.

set -u

MODE=install
case "${1:-}" in
  status|--status|-s) MODE=status ;;
  install|--install|"") MODE=install ;;
  *) printf 'usage: nod-bootstrap [status]\n' >&2; exit 2 ;;
esac

NOD_HOME="${HOME:-/data/data/com.termux.nix/files/home}"
NOD_FLAKE="${NOD_FLAKE:-github:MarcPartensky/nixos}"
NOD_DEVICE="${NOD_DEVICE:-}"
NOD_TTL="${NOD_TTL:-0}"
GEN_BIN=/nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin

say()  { printf '>>> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }
die()  { printf '!!! %s\n' "$*" >&2; printf 'NOD-BOOTSTRAP-FAILED\n'; exit 1; }
ok()   { printf ' ok  %s\n' "$*"; }

# Resolves a binary: current generation, then user profile, then PATH.
# The current generation is the STABLE path set by nix-on-droid: it survives
# a switch and always resolves the active environment.
find_bin() {
  name=$1
  for p in "$GEN_BIN/$name" "$NOD_HOME/.nix-profile/bin/$name"; do
    if [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
  done
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
  return 1
}

say "nod-bootstrap, mode=$MODE, $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo 'unknown date')"
say "home=$NOD_HOME"
case "$NOD_HOME" in
  */com.termux.nix/*|*/termux.nix/*) ok "Nix-on-Droid environment recognized" ;;
  *) warn "unexpected HOME: this script targets the Nix-on-Droid app (com.termux.nix). Continuing anyway." ;;
esac

# --- state only --------------------------------------------------------------
report_state() {
  s=0
  for b in sshd phone-up phone-status phone-watchdog zsh git; do
    if p=$(find_bin "$b"); then ok "$b -> $p"; else warn "$b MISSING"; s=1; fi
  done
  if [ -x "$GEN_BIN/phone-status" ]; then
    say "phone-status :"
    "$GEN_BIN/phone-status" || warn "phone-status failed"
  fi
  if p=$(find_bin curl); then ok "curl -> $p"; else warn "curl MISSING (the short link will not be relaunchable on this device)"; fi
  return $s
}

if [ "$MODE" = status ]; then
  report_state || warn "incomplete state"
  printf 'NOD-BOOTSTRAP-STATUS-DONE\n'
  exit 0
fi

# --- relay key (optional) ---------------------------------------------------
if [ -n "${NOD_RELAY_KEY:-}" ]; then
  say "writing the relay key to ~/.ssh/relay_ed25519"
  umask 077
  mkdir -p "$NOD_HOME/.ssh"
  if printf '%s' "$NOD_RELAY_KEY" | base64 -d > "$NOD_HOME/.ssh/relay_ed25519" 2>/dev/null; then
    chmod 600 "$NOD_HOME/.ssh/relay_ed25519"
    ok "relay key set (outbound tunnel to the active VPS at the next phone-up)"
  else
    warn "unreadable base64: key NOT set"
  fi
  unset NOD_RELAY_KEY
fi

# --- declarative switch -----------------------------------------------------
NOD_BIN_CONF=$(find_bin nix-on-droid) \
  || die "nix-on-droid binary not found: first install the Nix-on-Droid app (F-Droid, com.termux.nix) and answer the flakes question there."

if [ "${NOD_NO_SWITCH:-0}" = 1 ]; then
  say "NOD_NO_SWITCH=1: switch skipped"
else
  TARGET="$NOD_FLAKE"
  [ -n "$NOD_DEVICE" ] && TARGET="$NOD_FLAKE#$NOD_DEVICE"
  say "switch from $TARGET (tarball-ttl $NOD_TTL)"
  say "first build: several minutes, the screen may seem frozen. Do not close the app."
  # The nix fetcher caches unpinned refs (~1 h): tarball-ttl 0
  # forces a fresh resolution, essential right after a config push.
  # The switch kills neither sshd nor the already-started loops: the session survives.
  if [ "$NOD_TTL" = 0 ]; then
    "$NOD_BIN_CONF" switch --flake "$TARGET" --option tarball-ttl 0
  else
    "$NOD_BIN_CONF" switch --flake "$TARGET" --option tarball-ttl "$NOD_TTL"
  fi || die "the switch failed: read the last 20 lines above (often a file name or a variable misnamed in a module)."
  ok "active generation"
fi

# --- starting the services --------------------------------------------------
if p=$(find_bin phone-up); then
  say "phone-up (sshd, tunnels, watchdog, wake-lock)"
  "$p" || warn "phone-up returned a non-zero code (see ~/sshd/up.log)"
else
  warn "phone-up absent from the profile: the switch did not deploy the access module (check profiles/nix-on-droid)."
fi
sleep 3

# --- verification ------------------------------------------------------------
say "verification"
FAIL=0
for b in sshd phone-up phone-status zsh git; do
  if p=$(find_bin "$b"); then ok "$b"; else warn "$b MISSING"; FAIL=1; fi
done
if p=$(find_bin curl); then ok "curl (the short link is relaunchable on this device)"; else warn "curl absent: the device will not be able to re-bootstrap itself (add curl to environment.packages)"; fi

# does sshd listen? (app uid: no ss/netlink, but /dev/tcp is enough)
if timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8023' 2>/dev/null; then
  ok "sshd reachable on 127.0.0.1:8023"
else
  warn "sshd does not answer on 127.0.0.1:8023 (relaunch phone-up; otherwise read ~/sshd/up.log)"
  FAIL=1
fi

# LAN IP: under the app uid, netlink reading is sometimes refused, we tolerate it.
if p=$(find_bin ip); then
  LAN=$("$p" -4 -o addr show wlan0 2>/dev/null | grep -o '[0-9][0-9.]*/[0-9]*' | head -1 | cut -d/ -f1)
  [ -n "$LAN" ] && ok "wlan0 = $LAN  (ssh -p 8023 nix-on-droid@$LAN)"
fi

if [ -x "$GEN_BIN/phone-status" ]; then
  say "phone-status :"
  "$GEN_BIN/phone-status" || warn "phone-status failed"
fi

cat <<'CHECKLIST'

--- the 4 Android settings that keep the device alive (once) -------------------
 1. Nix-on-Droid: automatic start ON (Settings > Apps > Nix-on-Droid)
 2. battery: NO restriction (otherwise the HyperOS app killer freezes the app)
 3. permission "Display pop-up windows" (required by the wake-lock)
 4. lock the app in the recents (padlock)
 check: in a session, `termux-wake-lock; echo $?` must display 0

--- afterwards ------------------------------------------------------------
 relaunching the same short command = update + repair (idempotent)
 state:  /nix/var/nix/profiles/nix-on-droid/nix-on-droid-path/bin/nod-bootstrap status
CHECKLIST

if [ "$FAIL" = 0 ]; then
  printf 'NOD-BOOTSTRAP-OK\n'
else
  printf 'NOD-BOOTSTRAP-OK-AVEC-RESERVES\n'
fi
exit 0
