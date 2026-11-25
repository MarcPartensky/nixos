#!/usr/bin/env bash
# Choisit les builders nix distants (laptop, deck) EN FONCTION DE LA CHARGE.
#
# Politique marc (25/11/2026) : aucun job de build ne compile sur tower. Les
# builds partent sur le laptop ou le deck, choisis par overload. Tower (la
# machine interactive de marc) n'est JAMAIS un builder.
#
# Sortie (stdout) : la valeur a passer a `nix --builders`, une entree par
# machine retenue, au format `nix.conf(5)` :
#   ssh-ng://hermes@<hote> x86_64-linux <cle> <max-jobs> 1 <features>
# Vide si aucune machine n'est joignable : l'appelant decide alors quoi faire
# (le wrapper nixos-rebuild-gated, lui, refuse de compiler sur tower).
#
# Criteres : la machine est retenue si la cle nix-builder l'authentifie, si elle
# a au moins MIN_HEADROOM coeurs libres (nproc - load1) et MIN_FREE_MB de RAM
# disponible. Un hote sature est donc exclu tout seul ; si AUCUN hote ne passe
# les seuils mais qu'un hote repond, on garde le moins charge (mieux que
# compiler sur tower).
set -uo pipefail

DOMAIN="ts.marcpartensky.com"
HOSTS=("laptop" "deck")
KEY="/var/lib/hermes/.ssh/nix-builder"
MAXJOBS=4
FEATURES="big-parallel,benchmark,nixos-test"
MIN_HEADROOM=1
MIN_FREE_MB=2048
CONNECT_TIMEOUT=5

probe() {
  # $1 = hote -> "headroom free_mb" sur stdout, rc != 0 si injoignable
  local h=$1 out nproc load freemb
  out=$(ssh -o BatchMode=yes \
           -o ConnectTimeout="$CONNECT_TIMEOUT" \
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
  # load1 absent -> on considere la machine saturee plutot que libre
  case "$load" in ''|*[!0-9.]*) load=999 ;; esac
  awk -v n="$nproc" -v l="$load" -v f="$freemb" 'BEGIN { printf "%d %d\n", n-l, f }'
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for h in "${HOSTS[@]}"; do
  ( probe "$h" > "$tmp/$h" 2>/dev/null ) &
done
# `wait` renvoie le code du dernier job : une sonde injoignable (rc 1) ferait
# avorter le script sous `set -e` (writeShellApplication).
wait || true

declare -A HEAD FREE
best_host=""; best_head=-99999
for h in "${HOSTS[@]}"; do
  read -r head free < "$tmp/$h" 2>/dev/null || continue
  HEAD[$h]=$head; FREE[$h]=$free
  printf 'builder-probe %-8s headroom=%s coeurs free=%s Mo\n' "$h" "$head" "$free" >&2
  if [ "$head" -gt "$best_head" ]; then best_head=$head; best_host=$h; fi
done

if [ -z "$best_host" ]; then
  printf 'builder-probe AUCUN builder joignable (laptop, deck)\n' >&2
  exit 0
fi

selected=()
for h in "${HOSTS[@]}"; do
  [ -n "${HEAD[$h]:-}" ] || continue
  if [ "${HEAD[$h]}" -ge "$MIN_HEADROOM" ] && [ "${FREE[$h]}" -ge "$MIN_FREE_MB" ]; then
    selected+=("$h")
  else
    printf 'builder-probe %-8s exclu (headroom=%s free=%s Mo)\n' "$h" "${HEAD[$h]}" "${FREE[$h]}" >&2
  fi
done

if [ ${#selected[@]} -eq 0 ]; then
  printf 'builder-probe tous les hotes sont charges : repli sur %s (le moins charge)\n' "$best_host" >&2
  selected=("$best_host")
fi

spec=""
for h in "${selected[@]}"; do
  spec="${spec}${spec:+ }ssh-ng://hermes@${h}.${DOMAIN} x86_64-linux ${KEY} ${MAXJOBS} 1 ${FEATURES}"
done
printf '%s\n' "$spec"
