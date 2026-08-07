#!/bin/sh
# Regression: the ClamAV scan runs on Alpine/BusyBox, whose find rejects GNU's
# -false. This guards against reintroducing a GNU-only predicate that would make
# scans silently match zero files. Requires busybox; skips cleanly if absent.
set -eu
SCRIPT="$(dirname "$0")/../files/scripts/scan.sh"

# 1. Static guard: no GNU-only -false in the scan script.
if grep -Eq '[[:space:](]-false([[:space:]]|$)' "$SCRIPT"; then
  echo "FAIL: scan.sh uses GNU-only -false (breaks BusyBox find)"; exit 1
fi
echo "PASS: no -false in scan.sh"

# 2. Functional: the exact prune/find logic finds files and excludes dirs
#    under BusyBox find.
if ! command -v busybox >/dev/null 2>&1; then
  echo "SKIP: busybox not available for functional find test"; exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/Movies" "$T/.backups" "$T/.clamav-reports" "$T/usenet/incomplete" "$T/usenet/complete"
echo a > "$T/Movies/m.mkv"
echo b > "$T/.backups/x.tar"
echo c > "$T/usenet/incomplete/p.part"
echo d > "$T/usenet/complete/done.mkv"

EXCLUDE_DIRS="$T/.backups:$T/.clamav-reports:$T/usenet/incomplete"
set --
OLDIFS=$IFS; IFS=:
for d in $EXCLUDE_DIRS; do
  [ -n "$d" ] || continue
  if [ "$#" -eq 0 ]; then set -- -path "$d"; else set -- "$@" -o -path "$d"; fi
done
IFS=$OLDIFS
COUNT=$(busybox find "$T" \( "$@" \) -prune -o -type f -print 2>/dev/null | wc -l | tr -d ' ')
if [ "$COUNT" -ne 2 ]; then
  echo "FAIL: expected 2 scannable files, got $COUNT"; exit 1
fi
echo "PASS: BusyBox find returns 2 files, excludes pruned dirs"
