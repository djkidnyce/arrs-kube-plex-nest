#!/bin/sh
# VPN rotator + supervisor for the gluetun sidecar.
#
# Two responsibilities:
#
#  1) SUPERVISE (every SUPERVISE_SECS): if gluetun's OpenVPN is in the "stopped"
#     state, start it again. gluetun's own healthcheck restarts a tunnel that is
#     running-but-unhealthy, but it deliberately leaves an *intentionally*
#     stopped tunnel alone. So a rotation whose "running" call failed, or a
#     restart of this rotator container, could leave the tunnel stopped
#     indefinitely — which caused a multi-hour outage. This loop guarantees the
#     tunnel is never left stopped: it checks, and if it is down it starts it
#     and retries, instead of failing and giving up.
#
#  2) ROTATE (on the interval): stop then start to pick a new exit server, then
#     VERIFY it returned to "running", retrying rather than leaving it down.
#
# gluetun >= v3.40 requires control-server auth; the API key comes from
# GLUETUN_APIKEY (the gluetun-control-auth Secret). All calls are to the local
# control API over the shared pod network (localhost:8000).
set -u
API="http://localhost:8000"
CONF="/etc/vpn-rotation/rotation-interval-seconds"
APIKEY="${GLUETUN_APIKEY:-}"
SUPERVISE_SECS=60
START_RETRIES=6
START_WAIT=10

log() { echo "[vpn-rotator] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }
log "started (supervisor mode)"
[ -z "$APIKEY" ] && log "WARNING: GLUETUN_APIKEY is empty — control API calls will fail (gluetun >= v3.40 requires auth)"

# Current OpenVPN state per gluetun: prints running | stopped | (empty if the
# control API is unreachable, e.g. gluetun still starting — in which case we do
# nothing and re-check next cycle).
vpn_status() {
  curl -sf -H "X-API-Key: ${APIKEY}" "${API}/v1/openvpn/status" 2>/dev/null \
    | sed -n 's/.*"status" *: *"\([a-z]*\)".*/\1/p'
}

set_vpn() {  # set_vpn running|stopped
  curl -sf -X PUT -H 'Content-Type: application/json' -H "X-API-Key: ${APIKEY}" \
    -d "{\"status\":\"$1\"}" "${API}/v1/openvpn/status" >/dev/null 2>&1
}

# Start the tunnel and wait until gluetun reports it running. Retries instead of
# giving up, so a bad server or a transient control-API hiccup self-heals.
bring_up() {
  n=1
  while [ "$n" -le "$START_RETRIES" ]; do
    [ "$(vpn_status)" = "running" ] && { [ "$n" -gt 1 ] && log "tunnel is running again"; return 0; }
    log "tunnel not running — starting (attempt ${n}/${START_RETRIES})"
    set_vpn running
    sleep "$START_WAIT"
    n=$((n + 1))
  done
  log "ERROR: tunnel did not reach 'running' after ${START_RETRIES} attempts; will retry next supervise cycle"
  return 1
}

read_interval() {
  i=3600
  if [ -f "$CONF" ]; then
    v=$(tr -d '[:space:]' < "$CONF")
    [ -n "$v" ] && i="$v"
  fi
  echo "$i"
}

countdown=$(read_interval)
if [ "$countdown" -gt 0 ] 2>/dev/null; then log "rotation enabled — next rotation in ${countdown}s"; else log "rotation disabled — supervising only"; fi

while true; do
  # 1) Supervise: never leave the tunnel stopped.
  st=$(vpn_status)
  if [ "$st" = "stopped" ]; then
    log "tunnel is stopped but should be up — self-healing"
    bring_up
  fi

  interval=$(read_interval)

  # Rotation disabled: supervise only.
  if ! [ "$interval" -gt 0 ] 2>/dev/null; then
    countdown=0
    sleep "$SUPERVISE_SECS"
    continue
  fi

  # Re-arm the countdown if rotation was just re-enabled.
  if ! [ "$countdown" -gt 0 ] 2>/dev/null; then
    countdown="$interval"
    log "rotation enabled — next rotation in ${countdown}s"
  fi

  countdown=$((countdown - SUPERVISE_SECS))
  if [ "$countdown" -le 0 ]; then
    log "rotating exit server"
    set_vpn stopped
    sleep 4
    set_vpn running
    bring_up
    countdown=$(read_interval)
    log "rotation complete — next rotation in ${countdown}s"
  fi

  sleep "$SUPERVISE_SECS"
done
