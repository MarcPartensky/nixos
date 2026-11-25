#!/usr/bin/env bash
# scripts/photos-pull.sh
# Pulls marc's phone photos to tower, source by source.
#
# TWO TRANSPORTS, a single entry point:
#   - ssh: `ssh phone` + tar in a stream. No physical action, BUT the
#     Nix-on-Droid app must have storage permission: without it, Android
#     refuses to read /storage/emulated/0 even over ssh (OS permission,
#     not a credential we could obtain from tower).
#   - adb: `adb exec-out tar` (fallback `adb pull -a`). Works without this
#     permission, but requires the USB cable or wireless debugging.
#
# WHY the transfer starts from tower in both cases: the phone shell does not
# read /storage/emulated/0 (scoped storage) and hosts no file
# server. Nothing can therefore be pushed FROM the phone to tower.
#
# Resume: a marker per already-pulled subdirectory ($ROOT/.pulled/<src>-<slug>).
# Rerunning the same command resumes what is missing without redoing the rest, which
# matters behind a relay (around 0.2 MB/s).
#
# Usage:
#   scripts/photos-pull.sh                    # everything, automatic transport
#   scripts/photos-pull.sh camera             # a single source
#   scripts/photos-pull.sh --dry-run          # what would be pulled
#   scripts/photos-pull.sh --force whatsapp   # ignore the markers
#   scripts/photos-pull.sh --via adb          # force a transport (adb|ssh)
set -euo pipefail

# Tree of the `photos` group (marc + hermes, 2770 setgid): a hermes session
# opened before the group creation ignores it -> re-execution via sg.
if ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx photos; then
  exec sg photos -c "$(printf '%q ' "$0" "$@")"
fi

ROOT=${PHOTOS_ROOT:-/home/marc/media/photos}
MARKERS="$ROOT/.pulled"
# Number of entries per tar stream (one photo per stream = one ssh handshake per
# photo). PHOTOS_BATCH=1 restores the old behavior for a diagnostic.
BATCH=${PHOTOS_BATCH:-200}
SSH_HOST=${SSH_HOST:-phone}
STORAGE=/storage/emulated/0
ADB=${ADB:-$(command -v adb 2>/dev/null || ls -d /nix/store/*android-tools-*/bin/adb 2>/dev/null | tail -1 || true)}

declare -A REMOTE_PATHS=(
  [camera]="$STORAGE/DCIM/Camera $STORAGE/DCIM/Screenshots $STORAGE/Pictures"
  [whatsapp]="$STORAGE/Android/media/com.whatsapp/WhatsApp/Media"
  [messenger]="$STORAGE/Android/media/com.facebook.orca $STORAGE/Android/data/com.facebook.orca"
)

DRY_RUN=0
FORCE=0
VIA=auto
# ONLY=photos|videos|all: filter by extension on the phone side (useful for DCIM/Camera
# where two thirds of the volume are videos). `all` does subdirectory by
# subdirectory, `photos`/`videos` go through a file list
# (find | tar -T -): toybox tar can read a list on stdin, verified.
ONLY=${ONLY:-all}
WANTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --via) VIA=${2:-auto}; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) WANTED+=("$1") ;;
  esac
  shift
done
[ ${#WANTED[@]} -eq 0 ] && WANTED=(camera whatsapp messenger)

# --- transport selection ----------------------------------------------------
ssh_ok() { timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" true >/dev/null 2>&1; }
ssh_can_read() { timeout 40 ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; ls $STORAGE" >/dev/null 2>&1; }
adb_serial() {
  [ -n "$ADB" ] && [ -x "$ADB" ] || return 1
  local s
  s=$("$ADB" devices 2>/dev/null | awk '$2 == "device" && $1 !~ /^emulator-/ {print $1; exit}')
  # awk outputs 0 even with no result: without this test, an adb with no device passed
  # as a valid transport and the script talked to an empty SERIAL.
  [ -n "$s" ] || return 1
  printf '%s\n' "$s"
}

SERIAL=""
TRANSPORT=none
case "$VIA" in
  ssh) ssh_ok && ssh_can_read && TRANSPORT=ssh || TRANSPORT=none ;;
  adb) SERIAL=$(adb_serial) && TRANSPORT=adb || TRANSPORT=none ;;
  auto)
    if ssh_ok && ssh_can_read; then
      TRANSPORT=ssh
    elif SERIAL=$(adb_serial); then
      TRANSPORT=adb
    fi
    ;;
  *) echo "unknown transport: $VIA (adb, ssh or auto)" >&2; exit 2 ;;
esac

if [ "$TRANSPORT" = none ]; then
  reach="unreachable"
  if ssh_ok; then
    reach="reachable over ssh, but /storage/emulated/0 is refused (storage permission missing)"
  fi
  cat >&2 <<EOF
No usable transport to pull the photos.

  ssh $SSH_HOST: $reach
  adb: $( [ -n "${SERIAL:-}" ] && echo "device $SERIAL" || echo "no device in 'device' state" )

The action that unblocks the most (no cable, no toggle per boot):
  phone > Settings > Apps > Nix-on-Droid > Permissions >
  Files and media > "Allow management of all files".
  Then this script switches to ssh on its own, nothing else to do.

Another way: USB cable on tower, or Wireless debugging (port shown).
EOF
  exit 1
fi

echo "transport: $TRANSPORT$( [ "$TRANSPORT" = adb ] && echo " (device $SERIAL)" || echo " (ssh $SSH_HOST)" )"

# --- remote access ----------------------------------------------------------
# PATH /system/bin on the phone side: toybox provides tar, find, du, ls.
remote_tar() { # $1=remote dir  $2..=names relative to this dir
  # The tar starts from the directory itself. The old version took dirname($1),
  # so for /DCIM/Camera it looked for "Facebook" in /DCIM: everything
  # failed with "tar: Facebook: No such file or directory" (bug invisible
  # as long as the storage permission was missing, the script exited before).
  #
  # `</dev/null` is MANDATORY: ssh reads its standard input, which here is the
  # `while read` loop of pull_dir. Without this redirection, the first call
  # swallowed the remaining lines of the list and the pass stopped after a
  # single entry, without an error message.
  local dir="$1"
  shift
  local names=() quoted="" n
  for n in "$@"; do
    names+=("$n")
    quoted="$quoted'$n' "
  done
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" exec-out tar -C "$dir" -cf - "${names[@]}" </dev/null ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; tar -C '$dir' -cf - $quoted" </dev/null ;;
  esac
}
remote_ls() { # $1=dir
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" shell "ls -1 '$1'" </dev/null ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; ls -1 '$1'" </dev/null ;;
  esac
}
remote_du() { # $1=dir
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" shell "du -sh '$1' 2>/dev/null | cut -f1" </dev/null ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; du -sh '$1' 2>/dev/null | cut -f1" </dev/null ;;
  esac
}
remote_is_dir() {
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" shell "[ -d '$1' ]" >/dev/null 2>&1 ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "test -d '$1'" >/dev/null 2>&1 ;;
  esac
}

# Extensions per mode. jpg/heic cover marc's camera.
case "$ONLY" in
  photos) FIND_FILTER='\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" -o -iname "*.webp" -o -iname "*.gif" -o -iname "*.bmp" \)' ;;
  videos) FIND_FILTER='\( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.3gp" -o -iname "*.mkv" -o -iname "*.webm" -o -iname "*.avi" \)' ;;
  all) FIND_FILTER='' ;;
  *) echo "unknown ONLY: $ONLY (photos, videos or all)" >&2; exit 2 ;;
esac

# Stream of an ENTIRE TREE filtered by extension, in a single tar (the list of
# files goes through stdin, toybox tar reads it with -T -).
remote_tar_filtered() { # $1=remote dir
  case "$TRANSPORT" in
    adb) "$ADB" -s "$SERIAL" shell "cd '$1' && find . -type f $FIND_FILTER -print | tar -cf - -T -" ;;
    ssh) ssh -o BatchMode=yes "$SSH_HOST" "export PATH=/system/bin:\$PATH; cd '$1' && find . -type f $FIND_FILTER -print | tar -cf - -T -" ;;
  esac
}

command -v tar >/dev/null 2>&1 || { echo "tar missing on tower" >&2; exit 1; }
mkdir -p "$MARKERS"

pull_dir() { # $1=source  $2=remote dir
  local source="$1" remote="$2" dest="$ROOT/$source"
  local parent sub slug marker n
  if ! remote_is_dir "$remote"; then
    echo "  $remote: absent or unreadable, ignored"
    return 0
  fi
  local subs
  subs=$(remote_ls "$remote" 2>/dev/null | tr -d '\r' | grep -v '^\.\{1,2\}$' || true)
  [ -n "$subs" ] || { echo "  $remote: empty"; return 0; }

  if [ $DRY_RUN -eq 1 ]; then
    # A `du` per entry would cost an ssh round-trip PER FILE (hours
    # on a flat gallery of several thousand files): a single
    # measurement of the directory is enough to know what is left to pull.
    echo "  $remote: $(printf '%s\n' "$subs" | wc -l) entries, $(remote_du "$remote" | tr -d '\r' | tr -d '\r')"
    return 0
  fi

  # Batch of N entries per tar stream. One stream per file (the old
  # behavior) added an ssh handshake per photo: on a flat gallery
  # of 7500 files, the overhead exceeded the transfer time. The markers
  # stay unitary (one per entry), so an interrupted batch only loses
  # that batch, and a rerun recomputes the batches from what is missing.
  local batch=() names=()
  flush_batch() {
    [ ${#names[@]} -eq 0 ] && return 0
    mkdir -p "$dest"
    echo "  -> $remote: ${#names[@]} entry(ies) from ${names[0]} to ${names[-1]}"
    if remote_tar "$remote" "${names[@]}" | tar -C "$dest" -xf -; then
      for n in "${batch[@]}"; do
        touch "$MARKERS/${source}-${n}"
      done
    else
      echo "     interrupted batch: rerun the same command to resume" >&2
      batch=()
      names=()
      return 1
    fi
    batch=()
    names=()
    return 0
  }

  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    case "$sub" in
      *"'"*) echo "  $remote/$sub: apostrophe in the name, ignored" >&2 ; continue ;;
    esac
    slug=$(printf '%s' "$remote/$sub" | tr '/ ' '__')
    marker="$MARKERS/${source}-${slug}"
    if [ $FORCE -eq 0 ] && [ -f "$marker" ]; then
      continue
    fi
    batch+=("$slug")
    names+=("$sub")
    if [ ${#names[@]} -ge $BATCH ]; then
      flush_batch || return 1
    fi
  done <<<"$subs"
  flush_batch || return 1
  return 0
}

rc=0
for source in "${WANTED[@]}"; do
  echo "=== $source ==="
  [ -n "${REMOTE_PATHS[$source]:-}" ] || { echo "  source inconnue : $source" >&2; rc=1; continue; }
  for remote in ${REMOTE_PATHS[$source]}; do
    if [ "$ONLY" = all ]; then
      pull_dir "$source" "$remote" || rc=1
    else
      # Filtered mode: a single stream per remote directory, marker per (source,
      # directory, mode) so that photos and videos are resumed independently.
      if ! remote_is_dir "$remote"; then
        echo "  $remote: absent or unreadable, ignored"
        continue
      fi
      slug=$(printf '%s' "$remote" | tr '/ ' '__')
      marker="$MARKERS/${source}-${slug}-${ONLY}"
      if [ $FORCE -eq 0 ] && [ -f "$marker" ]; then
        echo "  $remote ($ONLY): already pulled"
        continue
      fi
      if [ $DRY_RUN -eq 1 ]; then
        echo "  $remote ($ONLY): filtered by extension, $(remote_du "$remote" | tr -d '\r') total"
        continue
      fi
      mkdir -p "$ROOT/$source"
      echo "  -> $remote ($ONLY)"
      if remote_tar_filtered "$remote" | tar -C "$ROOT/$source" -xf -; then
        touch "$marker"
      else
        echo "     interrupted: rerun the same command to resume" >&2
        rc=1
      fi
    fi
  done
  if [ $DRY_RUN -eq 0 ] && [ -d "$ROOT/$source" ]; then
    echo "  local: $(find "$ROOT/$source" -type f | wc -l) files, $(du -sh "$ROOT/$source" | cut -f1)"
  fi
done

if [ $DRY_RUN -eq 0 ]; then
  cat <<'EOF'

Pull complete. Next:
  scripts/photos-mirror.sh     # push to Garage now (otherwise hourly timer)
  scripts/photos-status.sh     # compare the local tree and the buckets
EOF
fi
exit $rc
