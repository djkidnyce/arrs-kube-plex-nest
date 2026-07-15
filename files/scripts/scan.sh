#!/bin/sh
set -u
SCAN_TYPE="${SCAN_TYPE:-quick}"
SCAN_DIR="${SCAN_DIR:-/mnt/media}"
DB_PATH="${DB_PATH:-/var/lib/clamav}"
MAX_FILE_SIZE="${MAX_FILE_SIZE:-500M}"
NOTIFICATION_TYPE="${NOTIFICATION_TYPE:-ntfy}"
NOTIFY_ON_CLEAN="${NOTIFY_ON_CLEAN:-false}"
WEBHOOK_URL="${WEBHOOK_URL:-}"

notify() {
  TITLE="$1"; BODY="$2"; URGENCY="${3:-default}"
  [ -z "$WEBHOOK_URL" ] && { echo "[notify] WEBHOOK_URL not set"; return 0; }
  case "$NOTIFICATION_TYPE" in
    ntfy)
      PRIORITY=$([ "$URGENCY" = "urgent" ] && echo "urgent" || echo "default")
      TAGS=$([ "$URGENCY" = "urgent" ] && echo "rotating_light" || echo "white_check_mark")
      curl -sf "$WEBHOOK_URL" -H "Title: $TITLE" -H "Priority: $PRIORITY" -H "Tags: $TAGS" -d "$BODY" ;;
    discord)
      COLOR=$([ "$URGENCY" = "urgent" ] && echo "16711680" || echo "3066993")
      ESC=$(printf '%s' "$BODY" | sed 's/\\/\\\\/g; s/"/\\"/g')
      curl -sf -X POST "$WEBHOOK_URL" -H "Content-Type: application/json" \
        -d "{\"embeds\":[{\"title\":\"$TITLE\",\"description\":\"$ESC\",\"color\":$COLOR}]}" ;;
    slack)
      EMOJI=$([ "$URGENCY" = "urgent" ] && echo ":rotating_light:" || echo ":white_check_mark:")
      ESC=$(printf '%s' "$BODY" | sed 's/\\/\\\\/g; s/"/\\"/g')
      curl -sf -X POST "$WEBHOOK_URL" -H "Content-Type: application/json" \
        -d "{\"text\":\"$EMOJI *$TITLE*\n$ESC\"}" ;;
    gotify)
      PRIO=$([ "$URGENCY" = "urgent" ] && echo "9" || echo "5")
      ESC=$(printf '%s' "$BODY" | sed 's/\\/\\\\/g; s/"/\\"/g')
      curl -sf -X POST "$WEBHOOK_URL" -H "Content-Type: application/json" \
        -d "{\"title\":\"$TITLE\",\"message\":\"$ESC\",\"priority\":$PRIO}" ;;
    *)
      curl -sf -X POST "$WEBHOOK_URL" -H "Content-Type: text/plain" -d "$TITLE: $BODY" ;;
  esac
  RC=$?; [ $RC -eq 0 ] && echo "[notify] Sent ($NOTIFICATION_TYPE)" || echo "[notify] Failed (exit $RC)"
}

echo "=============================="
echo " ClamAV Media Scanner"
echo " Type : $SCAN_TYPE"
echo " Dir  : $SCAN_DIR"
echo " Start: $(date)"
echo "=============================="
echo ""
echo "[freshclam] Updating definitions..."
FRESH_LOG=$(freshclam --datadir="$DB_PATH" 2>&1); FRESH_RC=$?
printf '%s\n' "$FRESH_LOG" | grep -v "^$" | tail -10
if [ "$FRESH_RC" -ne 0 ]; then echo "[freshclam] WARNING: update failed (exit $FRESH_RC) — using existing defs."; fi

echo ""
if [ "$SCAN_TYPE" = "quick" ]; then
  echo "[scan] Files modified in last 24 hours..."
  find "$SCAN_DIR" -mtime -1 -type f 2>/dev/null > /tmp/scan-list.txt
else
  echo "[scan] All files (full scan)..."
  find "$SCAN_DIR" -type f 2>/dev/null > /tmp/scan-list.txt
fi

FILE_COUNT=$(wc -l < /tmp/scan-list.txt | tr -d ' ')
echo "[scan] Files to scan: $FILE_COUNT"

if [ "$FILE_COUNT" -eq 0 ]; then
  echo "[scan] Nothing to scan."
  [ "$NOTIFY_ON_CLEAN" = "true" ] && \
    notify "Media Scan: No Files" "No files matched criteria. Dir: $SCAN_DIR / $(date)" "default"
  exit 0
fi

echo "[scan] Running clamscan..."
SCAN_OUTPUT=$(clamscan \
  --file-list=/tmp/scan-list.txt \
  --database="$DB_PATH" \
  --infected \
  --suppress-ok-results \
  --max-filesize="$MAX_FILE_SIZE" \
  --max-scansize=1000M \
  --stdout 2>&1)
EXIT_CODE=$?
INFECTED=$(printf '%s' "$SCAN_OUTPUT" | grep -c "FOUND"); [ -z "$INFECTED" ] && INFECTED=0
LABEL=$([ "$SCAN_TYPE" = "quick" ] && echo "Daily Quick" || echo "Monthly Full")
echo "[scan] Exit: $EXIT_CODE | Infected: $INFECTED"
echo ""

case "$EXIT_CODE" in
  0)
    echo "[result] CLEAN — $FILE_COUNT file(s) scanned."
    [ "$NOTIFY_ON_CLEAN" = "true" ] && \
      notify "Media Scan: Clean ($LABEL)" "$FILE_COUNT file(s) scanned. No threats. $(date)" "default" ;;
  1)
    echo "[result] THREATS FOUND:"; echo "$SCAN_OUTPUT"
    PREVIEW=$(printf '%s' "$SCAN_OUTPUT" | head -30)
    notify "🚨 THREAT DETECTED — $INFECTED file(s)" \
      "$INFECTED infected file(s) in $LABEL scan!\n\n$PREVIEW\n\nFull list in pod logs. Dir: $SCAN_DIR / $(date)" "urgent"
    exit 1 ;;
  *)
    echo "[result] SCAN ERROR (exit $EXIT_CODE)"
    notify "⚠️ Media Scan Error ($LABEL)" \
      "ClamAV exited $EXIT_CODE. Check pod logs. Dir: $SCAN_DIR / $(date)" "default"
    exit "$EXIT_CODE" ;;
esac
echo "=== Done: $(date) ==="
