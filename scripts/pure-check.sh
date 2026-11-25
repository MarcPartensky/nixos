#!/usr/bin/env bash
# scripts/pure-check.sh
#
# Purity guard for the NixOS eval (marc's policy of 13/11/2026: no more
# impure build). A pure build breaks at the first unlocked reference or
# at the first absolute path read outside the repo. This script lists them.
#
# Usage: scripts/pure-check.sh [repo-path]
# Exit 0 = nothing to report, 1 = at least one impurity.
#
# What it looks for, and why:
#   1. builtins.getFlake -> requires --impure ("cannot call getFlake on unlocked
#      flake reference"). Way out: declare a locked input in
#      flake.lock, or copy the module into the repo.
#   2. callPackage/import/builtins.path on an ABSOLUTE path outside the repo ->
#      "cannot access absolute path in pure eval mode". Way out: copy
#      synced into the repo (e.g. services/thclaws/package.nix).
#   3. --impure in the Justfile or the scripts -> the builds launched by these
#      recipes stay impure even if the tree is clean.
#   4. import <nixpkgs> or /etc/nixos in a module -> NIX_PATH does not exist
#      in pure eval.
#
# Comments are ignored: they document exactly these pitfalls.

set -uo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo" || exit 2
self="scripts/pure-check.sh"

fail=0
say() { printf '%s\n' "$*"; }
bad() { printf 'IMPUR  %s\n' "$*"; fail=1; }

# Emits the lines <file>:<n>:<content> whose CONTENT is not a
# comment, excluding this script. $1 = regex, $2.. = grep options.
scan() {
  local re="$1"
  shift
  grep -rnE "$re" "$@" 2>/dev/null | awk -v self="./$self" '
    {
      i = index($0, ":")
      file = substr($0, 1, i - 1)
      if (file == self) next
      rest = substr($0, i + 1)
      j = index(rest, ":")
      content = substr(rest, j + 1)
      if (content ~ /^[ \t]*#/) next
      print $0
    }'
}

say "== repo: $repo"

while IFS= read -r line; do
  [ -n "$line" ] && bad "getFlake: $line"
done < <(scan 'builtins\.getFlake' --include='*.nix' .)

while IFS= read -r line; do
  case "$line" in
    *'/nix/store/'*) continue ;;
  esac
  [ -n "$line" ] && bad "absolute path evaluated: $line"
done < <(scan '(callPackage|import|scopedImport|builtins\.path|builtins\.readFile|builtins\.readDir)[[:space:]]+(/[A-Za-z]|\([[:space:]]*toString[[:space:]]+/)' --include='*.nix' .)

while IFS= read -r line; do
  [ -n "$line" ] && bad "--impure : $line"
done < <(scan '(^|[^[:alnum:]_])--impure' --include='Justfile' --include='justfile' --include='*.sh' .)

while IFS= read -r line; do
  [ -n "$line" ] && bad "implicit NIX_PATH: $line"
done < <(scan '(import[[:space:]]+<|/etc/nixos)' --include='*.nix' .)

if [ "$fail" -eq 0 ]; then
  say "OK: no impurity detected"
  say "Authoritative check: nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath (WITHOUT --impure)"
else
  say "---"
  say "Fix these points, then: nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"
fi
exit "$fail"
