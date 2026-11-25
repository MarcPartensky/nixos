#!/usr/bin/env bash
# winnie-idle: stop the winnie servers once nobody has been connected for a
# while. Run by winnie-idle.timer every 2 min.
#
# Why this exists: systemd has no idle timeout for socket-activated services.
# The sockets stay listening (winnie-frontend.socket, winnie-dev.socket), so
# stopping a service costs nothing: the first connection starts it again.
#
# Usage:
#   winnie-idle.sh              # normal tick (called by the timer)
#   winnie-idle.sh --dry-run    # show the decision, change nothing
#   winnie-idle.sh --force      # stop now, whatever the idle clock says
# Env:
#   WINNIE_IDLE_AFTER_S         # idle threshold in seconds (default 900)
set -euo pipefail

# Ports to watch, and the units to stop when they go quiet.
# 8787 (backend) is NOT here on purpose: its Pangolin target declares a
# healthcheck (services/newt/default.nix), which probes /healthz every 30 s and
# would wake it right back up. Sleep the backend only after that healthcheck is
# declared off in Nix.
PORTS=(8888 8080)
UNITS=(winnie-frontend.service winnie-dev.service)
IDLE_AFTER_S=${WINNIE_IDLE_AFTER_S:-900}

STATE_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
STATE="$STATE_DIR/winnie-idle.last"
NOW=$(date +%s)
MODE=${1:-}

busy=0
for port in "${PORTS[@]}"; do
  # An established connection means somebody is using the app (a loaded page
  # keeps its connection open). The listening socket itself is not counted.
  if ss -Htn state established "( sport = :$port )" | grep -q .; then
    busy=1
    busy_port=$port
  fi
done

if [ "$MODE" = "--dry-run" ]; then
  printf 'busy=%s busy_port=%s last=%s idle_after=%ss\n' \
    "$busy" "${busy_port:-none}" "$(cat "$STATE" 2>/dev/null || echo never)" "$IDLE_AFTER_S"
  exit 0
fi

if [ "$busy" = 1 ]; then
  printf '%s\n' "$NOW" > "$STATE"
  exit 0
fi

LAST=$(cat "$STATE" 2>/dev/null || printf '%s' "$NOW")
case "$LAST" in ''|*[!0-9]*) LAST=$NOW ;; esac
AGE=$(( NOW - LAST ))

if [ "$MODE" != "--force" ] && [ "$AGE" -lt "$IDLE_AFTER_S" ]; then
  echo "nobody connected for ${AGE}s (< ${IDLE_AFTER_S}s): leaving the servers up"
  exit 0
fi

for unit in "${UNITS[@]}"; do
  if systemctl --user is-active --quiet "$unit"; then
    echo "nobody connected for ${AGE}s: stopping $unit"
    systemctl --user stop "$unit"
  fi
done
printf '%s\n' "$NOW" > "$STATE"
