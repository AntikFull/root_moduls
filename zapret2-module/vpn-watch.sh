#!/system/bin/sh
# Hybrid VPN/tether watcher.
# Fast path: Android/netd writes in /data/misc/net -> inotify trigger.
# Safety path: lightweight link/address/rt_tables signature every 2 sec.
# Periodic role recheck catches vendor VPNs that change only Connectivity state.

MODDIR=${0%/*}
RUN_DIR="$MODDIR/run"
TRIGGER_FILE="$RUN_DIR/network-event.flag"
[ -f "$MODDIR/zapret2.conf" ] && . "$MODDIR/zapret2.conf"
: "${VPN_WATCH_INTERVAL:=2}" "${VPN_RETRY_INTERVAL:=1}" "${VPN_STATE_RECHECK:=10}"
case "$VPN_WATCH_INTERVAL" in ''|*[!0-9]*) VPN_WATCH_INTERVAL=2 ;; esac
case "$VPN_RETRY_INTERVAL" in ''|*[!0-9]*) VPN_RETRY_INTERVAL=1 ;; esac
case "$VPN_STATE_RECHECK" in ''|*[!0-9]*) VPN_STATE_RECHECK=10 ;; esac
[ "$VPN_WATCH_INTERVAL" -ge 1 ] 2>/dev/null || VPN_WATCH_INTERVAL=1
[ "$VPN_RETRY_INTERVAL" -ge 1 ] 2>/dev/null || VPN_RETRY_INTERVAL=1
[ "$VPN_STATE_RECHECK" -ge 4 ] 2>/dev/null || VPN_STATE_RECHECK=4

mkdir -p "$RUN_DIR" 2>/dev/null
rm -f "$TRIGGER_FILE" 2>/dev/null
snapshot() { "$MODDIR/vpn-routing.sh" signature 2>/dev/null; }

EVENT_PID=""
start_event_watcher() {
  [ -d /data/misc/net ] || return 0
  if command -v inotifyd >/dev/null 2>&1; then
    inotifyd "$MODDIR/network-event.sh" /data/misc/net:wcmynd 2>/dev/null &
    EVENT_PID=$!
  elif command -v busybox >/dev/null 2>&1; then
    busybox inotifyd "$MODDIR/network-event.sh" /data/misc/net:wcmynd 2>/dev/null &
    EVENT_PID=$!
  fi
}
cleanup() {
  [ -n "$EVENT_PID" ] && kill "$EVENT_PID" 2>/dev/null || true
  rm -f "$TRIGGER_FILE" 2>/dev/null
}
trap cleanup EXIT HUP INT TERM
start_event_watcher

last='__first__'
retrying=0
last_role_check=0
while :; do
  now=$(date +%s)
  current=$(snapshot)
  triggered=0
  periodic=0
  [ -e "$TRIGGER_FILE" ] && { triggered=1; rm -f "$TRIGGER_FILE" 2>/dev/null; }
  [ $((now - last_role_check)) -ge "$VPN_STATE_RECHECK" ] 2>/dev/null && periodic=1

  if [ "$current" != "$last" ] || [ "$triggered" = 1 ] || [ "$retrying" = 1 ] || [ "$periodic" = 1 ]; then
    # A fresh netd event often precedes the final TUN/table state by a fraction
    # of a second. Give it one short grace period; failed apply remains retrying.
    if [ "$triggered" = 1 ] && [ "$retrying" != 1 ]; then sleep 1; fi

    tether_rc=0
    "$MODDIR/tether-sync.sh" apply >/dev/null 2>&1 || tether_rc=$?
    vpn_rc=0
    if [ "${ENABLE_VPN_HOTSPOT:-0}" = "1" ]; then
      "$MODDIR/vpn-routing.sh" apply >/dev/null 2>&1 || vpn_rc=$?
    else
      "$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true
    fi
    last_role_check=$(date +%s)
    if [ "$tether_rc" = 0 ] && [ "$vpn_rc" = 0 ]; then
      last=$(snapshot)
      retrying=0
      sleep "$VPN_WATCH_INTERVAL"
    else
      retrying=1
      sleep "$VPN_RETRY_INTERVAL"
    fi
  else
    sleep "$VPN_WATCH_INTERVAL"
  fi
done
