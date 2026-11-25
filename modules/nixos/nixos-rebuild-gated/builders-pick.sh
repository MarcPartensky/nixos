#!/usr/bin/env bash
# Picks the remote nix builders (laptop, deck) BASED ON LOAD.
#
# Marc's policy (2026-11-25): no build job compiles on tower. Builds go to the
# laptop or the deck, chosen by overload. Tower (marc's interactive machine) is
# NEVER a builder.
#
# Output (stdout): the value to pass to `nix --builders`, one entry per selected
# machine, one machine PER LINE (nix splits the value on newlines), in the
# nix.conf(5) format:
#   ssh-ng://hermes@<host> x86_64-linux <key> <max-jobs> 1 <features>
# Empty when no machine is reachable: the caller then decides what to do (the
# nixos-rebuild-gated wrapper refuses to compile on tower).
#
# Criteria: a machine is kept if the nix-builder key authenticates it, if it has
# at least MIN_HEADROOM free cores (nproc - load1) and MIN_FREE_MB of available
# RAM. A saturated host is therefore excluded on its own; if NO host passes the
# thresholds but one answers, the least loaded one is kept (better than
# compiling on tower).
set -uo pipefail

DOMAIN="ts.marcpartensky.com"
HOSTS=("laptop" "deck")
KEY="/var/lib/hermes/.ssh/nix-builder"
MAXJOBS=4
FEATURES="big-parallel,benchmark,nixos-test"
MIN_HEADROOM=1
MIN_FREE_MB=2048
CONNECT_TIMEOUT=5
# Hard cap per probe: a sleeping host (closed laptop, DERP relay) accepts the
# TCP connection through the relay and then stops answering. ConnectTimeout only
# covers the TCP handshake: without `timeout` the probe would hang, and the
# switch with it.
PROBE_TIMEOUT=15

probe() {
  # $1 = host -> "headroom free_mb" on stdout, rc != 0 when unreachable
  local h=$1 out nproc load freemb
  # The probe runs on the remote host, so the single quotes are intentional:
  # the local shell must not expand $2. shellcheck's SC2016 is a false positive
  # here, and writeShellApplication turns it into a build failure.
  # shellcheck disable=SC2016
  out=$(timeout "$PROBE_TIMEOUT" ssh -o BatchMode=yes \
           -o ConnectTimeout="$CONNECT_TIMEOUT" \
           -o ConnectionAttempts=1 \
           -o ControlPath=none \
           -o IdentityAgent=none \
           -o PreferredAuthentications=publickey \
           -o NumberOfPasswordPrompts=0 \
           -o StrictHostKeyChecking=accept-new \
           "hermes@${h}.${DOMAIN}" \
           'nproc; cut -d" " -f1 /proc/loadavg; awk "/^MemAvailable:/{print int(\$2/1024)}" /proc/meminfo' 2>/dev/null) || return 1
  nproc=$(printf '%s\n' "$out" | sed -n 1p)
  load=$(printf '%s\n' "$out" | sed -n 2p)
  freemb=$(printf '%s\n' "$out" | sed -n 3p)
  case "$nproc" in ''|*[!0-9]*) return 1 ;; esac
  case "$freemb" in ''|*[!0-9]*) freemb=0 ;; esac
  # load1 missing -> consider the machine saturated rather than free
  case "$load" in ''|*[!0-9.]*) load=999 ;; esac
  awk -v n="$nproc" -v l="$load" -v f="$freemb" 'BEGIN { printf "%d %d\n", n-l, f }'
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for h in "${HOSTS[@]}"; do
  ( probe "$h" > "$tmp/$h" 2>/dev/null ) &
done
# `wait` returns the last job's status: an unreachable probe (rc 1) would abort
# the script under `set -e` (writeShellApplication).
wait || true

declare -A HEAD FREE
best_host=""; best_head=-99999
for h in "${HOSTS[@]}"; do
  read -r head free < "$tmp/$h" 2>/dev/null || continue
  HEAD[$h]=$head; FREE[$h]=$free
  printf 'builder-probe %-8s headroom=%s cores free=%s MB\n' "$h" "$head" "$free" >&2
  if [ "$head" -gt "$best_head" ]; then best_head=$head; best_host=$h; fi
done

if [ -z "$best_host" ]; then
  printf 'builder-probe NO builder reachable (laptop, deck)\n' >&2
  exit 0
fi

selected=()
for h in "${HOSTS[@]}"; do
  [ -n "${HEAD[$h]:-}" ] || continue
  if [ "${HEAD[$h]}" -ge "$MIN_HEADROOM" ] && [ "${FREE[$h]}" -ge "$MIN_FREE_MB" ]; then
    selected+=("$h")
  else
    printf 'builder-probe %-8s excluded (headroom=%s free=%s MB)\n' "$h" "${HEAD[$h]}" "${FREE[$h]}" >&2
  fi
done

if [ ${#selected[@]} -eq 0 ]; then
  printf 'builder-probe every host is loaded: falling back to %s (least loaded)\n' "$best_host" >&2
  selected=("$best_host")
fi

specs=()
for h in "${selected[@]}"; do
  specs+=("ssh-ng://hermes@${h}.${DOMAIN} x86_64-linux ${KEY} ${MAXJOBS} 1 ${FEATURES}")
done
# One machine per LINE, never space-joined on a single line: nix splits the
# `builders` value on newlines and then parses each line's fields by spaces, so
# a space-separated list is read as one machine with extra fields and fails with
# "while parsing machine specification ... invalid character in Base64 string".
# That broke every remote build as soon as laptop AND deck were both reachable.
printf '%s\n' "${specs[@]}"
