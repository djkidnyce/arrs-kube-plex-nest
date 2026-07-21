#!/bin/sh
# Update ClamAV signature databases on a schedule, independent of scans.
set -u
DB_PATH="${DB_PATH:-/var/lib/clamav}"
echo "[freshclam] Updating definitions in ${DB_PATH} at $(date)"
OUT=$(freshclam --datadir="$DB_PATH" 2>&1); RC=$?
printf '%s\n' "$OUT" | tail -20
if [ "$RC" -ne 0 ]; then
  echo "[freshclam] FAILED (exit $RC)"
  exit "$RC"
fi
echo "[freshclam] Definitions current at $(date)"
