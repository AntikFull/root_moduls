#!/system/bin/sh
# Low-overhead VPN/tether watcher.
# Fast path is event-driven (netlink + /data/misc/net inotify). Expensive Android
# role resolution is only performed after a coalesced event, during transitions,
# or at a low-frequency safety recheck. No per-2-second net-role snapshot polling.

umask 077
MODDIR=${0%/*}
RUN_DIR="$MODDIR/run"
TRIGGER_FILE="$RUN_DIR/network-event.flag"
NETLINK_FIFO="$RUN_DIR/netlink-events.fifo"
[ -f "$MODDIR/zapret2.conf" ] && . "$MODDIR/zapret2.conf"
: "${VPN_WATCH_INTERVAL:=2}" "${VPN_RETRY_INTERVAL:=1}" "${VPN_ROLE_RECHECK:=30}" "${VPN_VERIFY_INTERVAL:=60}" "${VPN_EVENT_DEBOUNCE:=2}" "${VPN_NETLINK_MONITOR:=1}"
: "${AUTO_SELECT_ENABLED:=1}" "${AUTO_PERIODIC_RECHECK:=1800}"
for v in VPN_WATCH_INTERVAL VPN_RETRY_INTERVAL VPN_ROLE_RECHECK VPN_VERIFY_INTERVAL VPN_EVENT_DEBOUNCE; do
  eval val=\$$v
  case "$val" in ''|*[!0-9]*) case "$v" in VPN_WATCH_INTERVAL) val=2 ;; VPN_RETRY_INTERVAL) val=1 ;; VPN_ROLE_RECHECK) val=30 ;; VPN_VERIFY_INTERVAL) val=60 ;; VPN_EVENT_DEBOUNCE) val=2 ;; esac; eval "$v=$val" ;; esac
done
[ "$VPN_WATCH_INTERVAL" -ge 1 ] 2>/dev/null || VPN_WATCH_INTERVAL=2
[ "$VPN_RETRY_INTERVAL" -ge 1 ] 2>/dev/null || VPN_RETRY_INTERVAL=1
[ "$VPN_ROLE_RECHECK" -ge 15 ] 2>/dev/null || VPN_ROLE_RECHECK=30
[ "$VPN_VERIFY_INTERVAL" -ge 30 ] 2>/dev/null || VPN_VERIFY_INTERVAL=60
[ "$VPN_EVENT_DEBOUNCE" -ge 1 ] 2>/dev/null || VPN_EVENT_DEBOUNCE=2
mkdir -p "$RUN_DIR" 2>/dev/null; chmod 0700 "$RUN_DIR" 2>/dev/null || true
rm -f "$TRIGGER_FILE" "$NETLINK_FIFO" 2>/dev/null

IP_BIN=$(command -v ip 2>/dev/null); [ -n "$IP_BIN" ] || IP_BIN=/system/bin/ip
role_snapshot() { "$MODDIR/net-role.sh" role-signature 2>/dev/null; }

EVENT_PID=""
IPMON_PID=""
IPMON_READER_PID=""

signal_event() {
  [ -e "$TRIGGER_FILE" ] || : > "$TRIGGER_FILE"
}

start_android_event_watcher() {
  [ -d /data/misc/net ] || return 0
  if command -v inotifyd >/dev/null 2>&1; then
    inotifyd "$MODDIR/network-event.sh" /data/misc/net:wcmynd 2>/dev/null & EVENT_PID=$!
  elif command -v busybox >/dev/null 2>&1; then
    busybox inotifyd "$MODDIR/network-event.sh" /data/misc/net:wcmynd 2>/dev/null & EVENT_PID=$!
  fi
}

start_netlink_monitor() {
  [ "$VPN_NETLINK_MONITOR" = "1" ] || return 0
  [ -x "$IP_BIN" ] || return 0
  rm -f "$NETLINK_FIFO" 2>/dev/null
  mkfifo "$NETLINK_FIFO" 2>/dev/null || return 0
  chmod 0600 "$NETLINK_FIFO" 2>/dev/null || true

  # Reader first: it blocks on the FIFO without CPU usage until ip monitor writes.
  (
    while IFS= read -r _line; do
      [ -e "$TRIGGER_FILE" ] || : > "$TRIGGER_FILE"
    done < "$NETLINK_FIFO"
  ) &
  IPMON_READER_PID=$!

  # ip monitor uses rtnetlink and blocks in the kernel. If this ip build does not
  # support monitor/all it exits; the periodic role safety check remains active.
  "$IP_BIN" monitor all > "$NETLINK_FIFO" 2>/dev/null &
  IPMON_PID=$!
}

cleanup() {
  [ -n "$EVENT_PID" ] && kill "$EVENT_PID" 2>/dev/null || true
  [ -n "$IPMON_PID" ] && kill "$IPMON_PID" 2>/dev/null || true
  [ -n "$IPMON_READER_PID" ] && kill "$IPMON_READER_PID" 2>/dev/null || true
  rm -f "$TRIGGER_FILE" "$NETLINK_FIFO" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 0' HUP INT TERM
start_android_event_watcher
start_netlink_monitor

now_epoch() {
  local n
  n=$(date +%s 2>/dev/null)
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

last_roles=$(role_snapshot)
now=$(now_epoch)
last_role_check=$now
last_verify=$now
last_auto_check=$now
retrying=0
event_pending=0
event_since=0

while :; do
  now=$(now_epoch)
  need_apply=0
  roles=""
  role_check_due=0

  # Лёгкий периодический триггер: auto-select сам применяет разный TTL для
  # Wi-Fi и мобильной сети и не выполняет HTTPS-probe, пока кэш свежий.
  if [ "$AUTO_SELECT_ENABLED" = 1 ] && [ "$AUTO_PERIODIC_RECHECK" -ge 300 ] 2>/dev/null && \
     [ $((now - last_auto_check)) -ge "$AUTO_PERIODIC_RECHECK" ] 2>/dev/null; then
    [ -x "$MODDIR/auto-select.sh" ] && sh "$MODDIR/auto-select.sh" schedule >/dev/null 2>&1 || true
    last_auto_check=$now
  fi

  if [ -e "$TRIGGER_FILE" ]; then
    rm -f "$TRIGGER_FILE" 2>/dev/null
    if [ "$event_pending" = 0 ]; then
      event_pending=1
      event_since=$now
    fi
  fi

  # During a transient interface state, retry quickly. This is intentionally the
  # only high-frequency path that may call the role resolver.
  if [ "$retrying" = 1 ]; then
    role_check_due=1
  elif [ "$event_pending" = 1 ] && [ $((now - event_since)) -ge "$VPN_EVENT_DEBOUNCE" ] 2>/dev/null; then
    role_check_due=1
  elif [ $((now - last_role_check)) -ge "$VPN_ROLE_RECHECK" ] 2>/dev/null; then
    role_check_due=1
  fi

  if [ "$role_check_due" = 1 ]; then
    roles=$(role_snapshot)
    last_role_check=$now
    event_pending=0
    event_since=0
    if [ "$roles" != "$last_roles" ]; then
      need_apply=1
      # События уже объединены debounce. AUTO будим только после реального
      # изменения сетевой роли/default upstream, а не на каждый vendor event.
      [ "$AUTO_SELECT_ENABLED" = 1 ] && [ -x "$MODDIR/auto-select.sh" ] && \
        sh "$MODDIR/auto-select.sh" schedule >/dev/null 2>&1 || true
      last_auto_check=$now
    fi
    [ "$retrying" = 1 ] && need_apply=1
  fi

  # Low-frequency drift detection. It does not rebuild anything when rules match.
  if [ "$need_apply" = 0 ] && [ $((now - last_verify)) -ge "$VPN_VERIFY_INTERVAL" ] 2>/dev/null; then
    tether_ok=0; vpn_ok=0
    "$MODDIR/tether-sync.sh" verify >/dev/null 2>&1 && tether_ok=1
    if [ "${ENABLE_VPN_HOTSPOT:-0}" = "1" ]; then
      "$MODDIR/vpn-routing.sh" verify >/dev/null 2>&1 && vpn_ok=1
    else
      vpn_ok=1
    fi
    [ "$tether_ok" = 1 ] && [ "$vpn_ok" = 1 ] || need_apply=1
    last_verify=$now
  fi

  if [ "$need_apply" = 1 ]; then
    tether_rc=0
    "$MODDIR/tether-sync.sh" apply >/dev/null 2>&1 || tether_rc=$?
    vpn_rc=0
    if [ "${ENABLE_VPN_HOTSPOT:-0}" = "1" ]; then
      "$MODDIR/vpn-routing.sh" apply >/dev/null 2>&1 || vpn_rc=$?
    else
      "$MODDIR/vpn-routing.sh" cleanup >/dev/null 2>&1 || true
    fi

    if [ "$tether_rc" = 0 ] && [ "$vpn_rc" = 0 ]; then
      # Reuse the role snapshot that caused this apply when available. If apply was
      # caused only by drift verification, refresh roles once after repair.
      [ -n "$roles" ] || roles=$(role_snapshot)
      last_roles="$roles"
      now=$(now_epoch)
      last_role_check=$now
      last_verify=$now
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
