#!/bin/sh
# VPN rotator — cycles the gluetun OpenVPN connection on an interval.
# gluetun >= v3.40 requires control-server auth: the API key is injected via
# the GLUETUN_APIKEY env var (from the gluetun-control-auth Secret).
set -u
GLUETUN_API="http://localhost:8000"
CONFIG_FILE="/etc/vpn-rotation/rotation-interval-seconds"
APIKEY="${GLUETUN_APIKEY:-}"

echo "[vpn-rotator] Started at $(date)"
[ -z "$APIKEY" ] && echo "[vpn-rotator] WARNING: GLUETUN_APIKEY is empty — API calls will fail (gluetun >= v3.40 requires auth)"

api_put() {
  curl -sf -X PUT "${GLUETUN_API}/v1/openvpn/status" \
    -H 'Content-Type: application/json' \
    -H "X-API-Key: ${APIKEY}" \
    -d "$1"
}

while true; do
  INTERVAL=3600
  if [ -f "$CONFIG_FILE" ]; then
    VAL=$(tr -d '[:space:]' < "$CONFIG_FILE")
    [ -n "$VAL" ] && INTERVAL="$VAL"
  fi

  if [ "$INTERVAL" -le 0 ] 2>/dev/null; then
    echo "[vpn-rotator] Rotation disabled (interval=0). Checking again in 60s..."
    sleep 60
    continue
  fi

  echo "[vpn-rotator] Next rotation in ${INTERVAL}s..."
  sleep "$INTERVAL"

  echo "[vpn-rotator] Stopping VPN at $(date)..."
  if api_put '{"status":"stopped"}'; then
    sleep 4
    echo "[vpn-rotator] Restarting VPN with new random config..."
    if api_put '{"status":"running"}'; then
      echo "[vpn-rotator] Rotation complete at $(date)"
    else
      echo "[vpn-rotator] ERROR: failed to restart VPN"
    fi
  else
    echo "[vpn-rotator] ERROR: failed to stop VPN (check API key / gluetun logs)"
  fi
done
