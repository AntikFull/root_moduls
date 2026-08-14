#!/system/bin/sh

umask 077
MODDIR=${0%/*}
RUN_DIR="$MODDIR/run"
TRIGGER_FILE="$RUN_DIR/network-event.flag"
NETLINK_FIFO="$RUN_DIR/netlink-events.fifo"
[ -f "$MODDIR/zapret2.conf" ] && . "$MODDIR/zapret2.conf"
: "${VPN_WATCH_INTERVAL:=20}" "${VPN_RETRY_INTERVAL:=2}" "${VPN_ROLE_RECHECK:=120}" "${VPN_VERIFY_INTERVAL:=300}" "${VPN_EVENT_DEBOUNCE:=3}" "${VPN_NETLINK_MONITOR:=1}"
: "${AUTO_SELECT_ENABLED:=1}" "${AUTO_PERIODIC_RECHECK:=1800}"
for v in VPN_WATCH_INTERVAL VPN_RETRY_INTERVAL VPN_ROLE_RECHECK VPN_VERIFY_INTERVAL VPN_EVENT_DEBOUNCE; do
  eval val=\$$v
  case "$val" in ''|*[!0-9]*) case "$v" in VPN_WATCH_INTERVAL) val=20 ;; VPN_RETRY_INTERVAL) val=2 ;; VPN_ROLE_RECHECK) val=120 ;; VPN_VERIFY_INTERVAL) val=300 ;; VPN_EVENT_DEBOUNCE) val=3 ;; esac; eval "$v=$val" ;; esac
done
[ "$VPN_WATCH_INTERVAL" -ge 1 ] 2>/dev/null || VPN_WATCH_INTERVAL=20
[ "$VPN_RETRY_INTERVAL" -ge 1 ] 2>/dev/null || VPN_RETRY_INTERVAL=2
[ "$VPN_ROLE_RECHECK" -ge 15 ] 2>/dev/null || VPN_ROLE_RECHECK=120
[ "$VPN_VERIFY_INTERVAL" -ge 30 ] 2>/dev/null || VPN_VERIFY_INTERVAL=300
[ "$VPN_EVENT_DEBOUNCE" -ge 1 ] 2>/dev/null || VPN_EVENT_DEBOUNCE=3
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

NETLINK_READY=0
start_netlink_monitor() {
  [ "$VPN_NETLINK_MONITOR" = "1" ] || return 0
  [ -x "$IP_BIN" ] || return 0
  rm -f "$NETLINK_FIFO" 2>/dev/null
  mkfifo "$NETLINK_FIFO" 2>/dev/null || return 0
  chmod 0600 "$NETLINK_FIFO" 2>/dev/null || true

  # Основной цикл сам читает FIFO через `read -t`, поэтому отдельный
  # reader-подпроцесс больше не нужен. FIFO открывается на чтение И запись,
  # чтобы open() не блокировался и чтобы EOF не приходил при рестарте
  exec 9<> "$NETLINK_FIFO" || return 0

  # ip monitor uses rtnetlink and blocks in the kernel. Подписываемся только на
  # событий в минуту на людном Wi-Fi — цикл просыпался бы впустую.
  "$IP_BIN" monitor link address route >&9 2>/dev/null &
  IPMON_PID=$!
  sleep 1
  if ! kill -0 "$IPMON_PID" 2>/dev/null; then
    # Сборка ip без выбора объектов: возвращаемся к monitor all.
    "$IP_BIN" monitor all >&9 2>/dev/null &
    IPMON_PID=$!
    sleep 1
  fi
  kill -0 "$IPMON_PID" 2>/dev/null || return 0
  NETLINK_READY=1
}

# `read -t` есть в mksh (/system/bin/sh) и в busybox ash, но не гарантирован
# в любой оболочке, которую может подсунуть прошивка. Проверяем один раз.
READ_TIMEOUT_OK=0
probe_read_timeout() {
  [ "$NETLINK_READY" = 1 ] || return 0
  local probe="$RUN_DIR/read-probe.$$" line rc t0 t1
  mkfifo "$probe" 2>/dev/null || return 0
  exec 8<> "$probe" 2>/dev/null || { rm -f "$probe" 2>/dev/null; return 0; }
  # Шаг 1: данные уже в FIFO. Если оболочка не понимает -t, read завершится
  # ошибкой — и мы узнаем это, ни разу не заблокировавшись.
  echo probe >&8
  read -t 1 line <&8 2>/dev/null; rc=$?
  if [ "$rc" = 0 ]; then
    # Шаг 2: FIFO пуст. Код возврата таймаута отличается у mksh (142) и
    # busybox ash (1), поэтому опираемся на факт ожидания, а не на код.
    t0=$(date +%s 2>/dev/null)
    read -t 1 line <&8 2>/dev/null; rc=$?
    t1=$(date +%s 2>/dev/null)
    case "$t0:$t1" in
      *[!0-9:]*|:*|*:) ;;
      *) [ "$rc" != 0 ] && [ $((t1 - t0)) -ge 1 ] 2>/dev/null && READ_TIMEOUT_OK=1 ;;
    esac
  fi
  exec 8>&- 2>/dev/null
  rm -f "$probe" 2>/dev/null
}

# спит в ядре: ни пробуждений таймера каждые 2 сек, ни форков `sleep`.
wait_for_event() {
  local timeout="$1" line
  if [ "$READ_TIMEOUT_OK" = 1 ]; then
    # Пачка событий одного изменения сети схлопывается debounce-ом в основном
    # цикле, поэтому достаточно проснуться на первой строке.
    read -t "$timeout" line <&9 2>/dev/null && signal_event
    return 0
  fi
  sleep "$timeout"
}

cleanup() {
  [ -n "$EVENT_PID" ] && kill "$EVENT_PID" 2>/dev/null || true
  [ -n "$IPMON_PID" ] && kill "$IPMON_PID" 2>/dev/null || true
  [ -n "$IPMON_READER_PID" ] && kill "$IPMON_READER_PID" 2>/dev/null || true
  exec 9>&- 2>/dev/null
  rm -f "$TRIGGER_FILE" "$NETLINK_FIFO" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 0' HUP INT TERM
start_android_event_watcher
start_netlink_monitor
probe_read_timeout

now_epoch() {
  local n
  n=$(date +%s 2>/dev/null)
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# Резервная периодическая проверка ролей эскалируется до дорогого
# net-role.sh role-signature (два dumpsys) лишь когда эта подпись изменилась.
cheap_snapshot() { "$MODDIR/net-role.sh" signature 2>/dev/null; }

last_roles=$(role_snapshot)
last_cheap=$(cheap_snapshot)
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

  if [ "$retrying" = 1 ]; then
    role_check_due=1
  elif [ "$event_pending" = 1 ] && [ $((now - event_since)) -ge "$VPN_EVENT_DEBOUNCE" ] 2>/dev/null; then
    role_check_due=1
  elif [ $((now - last_role_check)) -ge "$VPN_ROLE_RECHECK" ] 2>/dev/null; then
    # их состояния и адреса не менялись, роли измениться не могли — dumpsys
    # не запускаем вовсе.
    cheap=$(cheap_snapshot)
    if [ "$cheap" = "$last_cheap" ]; then
      last_role_check=$now
    else
      last_cheap=$cheap
      role_check_due=1
    fi
  fi

  if [ "$role_check_due" = 1 ]; then
    roles=$(role_snapshot)
    last_cheap=$(cheap_snapshot)
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
      [ -n "$roles" ] || roles=$(role_snapshot)
      last_roles="$roles"
      now=$(now_epoch)
      last_role_check=$now
      last_verify=$now
      retrying=0
      wait_for_event "$VPN_WATCH_INTERVAL"
    else
      retrying=1
      wait_for_event "$VPN_RETRY_INTERVAL"
    fi
  else
    wait_for_event "$VPN_WATCH_INTERVAL"
  fi
done
