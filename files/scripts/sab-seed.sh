#!/bin/sh
# Seed SABnzbd's config BEFORE SABnzbd starts.
#
# SABnzbd holds its configuration in memory and rewrites sabnzbd.ini on
# shutdown, so any edit made to a running instance is silently reverted. The
# only reliable moment to set these is before the process launches.
#
# Values come from the sabnzbd-seed ConfigMap.
set -u
INI="/config/sabnzbd.ini"

[ "${SEED_ENABLED:-true}" = "true" ] || { echo "[seed] disabled, skipping"; exit 0; }

# First boot: SABnzbd has not written its config yet. Create a minimal one so
# the settings apply immediately instead of only after a second restart.
# SABnzbd reads this on start and fills in every other default itself.
if [ ! -f "$INI" ]; then
  echo "[seed] No config yet — writing a minimal $INI"
  mkdir -p "$(dirname "$INI")" 2>/dev/null || true
  {
    echo "__version__ = 19"
    echo "__encoding__ = utf-8"
    echo "[misc]"
    echo "enable_https = ${ENABLE_HTTPS:-0}"
    echo "inet_exposure = ${INET_EXPOSURE:-4}"
    echo "host_whitelist = ${HOST_WHITELIST:-}"
    [ -n "${DOWNLOAD_DIR:-}" ] && echo "download_dir = ${DOWNLOAD_DIR}"
    [ -n "${COMPLETE_DIR:-}" ] && echo "complete_dir = ${COMPLETE_DIR}"
  } > "$INI" || { echo "[seed] WARNING: could not write $INI"; exit 0; }
  chmod 0644 "$INI" 2>/dev/null || true
  echo "[seed] done (fresh config)."
  cat "$INI"
  exit 0
fi

set_key() {
  key="$1"; val="$2"
  if grep -qE "^${key} = " "$INI"; then
    sed -i "s|^${key} = .*|${key} = ${val}|" "$INI"
    echo "[seed] set ${key} = ${val}"
  else
    # insert into the [misc] section if the key is absent
    if grep -q '^\[misc\]' "$INI"; then
      sed -i "/^\[misc\]/a ${key} = ${val}" "$INI"
      echo "[seed] inserted ${key} = ${val}"
    else
      echo "[seed] WARNING: no [misc] section; could not set ${key}"
    fi
  fi
}

set_key "enable_https"  "${ENABLE_HTTPS:-0}"
set_key "inet_exposure" "${INET_EXPOSURE:-4}"
[ -n "${DOWNLOAD_DIR:-}" ] && set_key "download_dir" "$DOWNLOAD_DIR"
[ -n "${COMPLETE_DIR:-}" ] && set_key "complete_dir" "$COMPLETE_DIR"

# Merge whitelist entries rather than replacing, so anything SABnzbd or the
# user added survives.
if [ -n "${HOST_WHITELIST:-}" ]; then
  existing=$(grep -E '^host_whitelist = ' "$INI" | sed 's|^host_whitelist = ||')
  merged=""
  # Word splitting on the translated commas drops empty fields, which also
  # normalises values SABnzbd writes with a trailing comma ("download,").
  for h in $(echo "${existing},${HOST_WHITELIST}" | tr ',' ' '); do
    [ -z "$h" ] && continue
    case ",${merged}," in
      *",${h},"*) ;;
      *) merged="${merged:+${merged},}${h}" ;;
    esac
  done
  set_key "host_whitelist" "$merged"
fi

echo "[seed] done."
grep -nE '^enable_https = |^inet_exposure|^host_whitelist' "$INI" || true
