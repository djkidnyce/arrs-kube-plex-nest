#!/bin/sh
set -u
GLUETUN_API="http://localhost:8000"
CONFIG_FILE="/etc/vpn-rotation/rotation-interval-seconds"

echo "[vpn-rotator] Started at $(date)"

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
  if curl -sf -X PUT "${GLUETUN_API}/v1/openvpn/status" \
       -H 'Content-Type: application/json' \
       -d '{"status":"stopped"}'; then
    sleep 4
    echo "[vpn-rotator] Restarting VPN with new random config..."
    if curl -sf -X PUT "${GLUETUN_API}/v1/openvpn/status" \
         -H 'Content-Type: application/json' \
         -d '{"status":"running"}'; then
      echo "[vpn-rotator] Rotation complete at $(date)"
    else
      echo "[vpn-rotator] ERROR: failed to restart VPN"
    fi
  else
    echo "[vpn-rotator] ERROR: failed to stop VPN"
  fi
done
