#!/usr/bin/env bash
# scripts/pure-check.sh
#
# Garde de purete de l'eval NixOS (politique marc du 13/11/2026 : plus aucun
# build impur). Un build pur casse a la premiere reference non verrouillee ou
# au premier chemin absolu lu hors du depot. Ce script les liste.
#
# Usage : scripts/pure-check.sh [chemin-du-depot]
# Sortie 0 = rien a signaler, 1 = au moins une impurete.
#
# Ce qu'il cherche, et pourquoi :
#   1. builtins.getFlake -> exige --impure ("cannot call getFlake on unlocked
#      flake reference"). Sortie : declarer un input verrouille dans
#      flake.lock, ou copier le module dans le depot.
#   2. callPackage/import/builtins.path sur un chemin ABSOLU hors depot ->
#      "cannot access absolute path in pure eval mode". Sortie : copie
#      synchronisee dans le depot (ex. services/thclaws/package.nix).
#   3. --impure dans le Justfile ou les scripts -> les builds lances par ces
#      recettes restent impurs meme si l'arbre est propre.
#   4. import <nixpkgs> ou /etc/nixos dans un module -> NIX_PATH n'existe pas
#      en eval pure.
#
# Les commentaires sont ignores : ils documentent justement les pieges.

set -uo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo" || exit 2
self="scripts/pure-check.sh"

fail=0
say() { printf '%s\n' "$*"; }
bad() { printf 'IMPUR  %s\n' "$*"; fail=1; }

# Emet les lignes <fichier>:<n>:<contenu> dont le CONTENU n'est pas un
# commentaire, en excluant ce script. $1 = regex, $2.. = options grep.
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

say "== depot : $repo"

while IFS= read -r line; do
  [ -n "$line" ] && bad "getFlake : $line"
done < <(scan 'builtins\.getFlake' --include='*.nix' .)

while IFS= read -r line; do
  case "$line" in
    *'/nix/store/'*) continue ;;
  esac
  [ -n "$line" ] && bad "chemin absolu evalue : $line"
done < <(scan '(callPackage|import|scopedImport|builtins\.path|builtins\.readFile|builtins\.readDir)[[:space:]]+(/[A-Za-z]|\([[:space:]]*toString[[:space:]]+/)' --include='*.nix' .)

while IFS= read -r line; do
  [ -n "$line" ] && bad "--impure : $line"
done < <(scan '(^|[^[:alnum:]_])--impure' --include='Justfile' --include='justfile' --include='*.sh' .)

while IFS= read -r line; do
  [ -n "$line" ] && bad "NIX_PATH implicite : $line"
done < <(scan '(import[[:space:]]+<|/etc/nixos)' --include='*.nix' .)

if [ "$fail" -eq 0 ]; then
  say "OK : aucune impurete detectee"
  say "Verification qui fait foi : nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath (SANS --impure)"
else
  say "---"
  say "Corrige ces points, puis : nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"
fi
exit "$fail"
