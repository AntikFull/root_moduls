#!/system/bin/sh
# Основная служба Zapret2 eCubz: правила NFQUEUE, nfqws2 и локальный WebUI.

MODDIR="${0%/*}"
CONF_FILE="$MODDIR/zapret2.conf"
APPS_LIST="$MODDIR/apps.list"
EXCLUDE_LIST="$MODDIR/exclude.list"
AUTO_DOMAINS_FILE="$MODDIR/auto_domains.list"
EXCLUDE_DOMAINS_FILE="$MODDIR/exclude_domains.list"
FORCE_TCP_APPS_LIST="$MODDIR/force_tcp_apps.list"
LOG_FILE="$MODDIR/zapret2.log"
BIN_DIR="$MODDIR/system/bin"
RUN_DIR="$MODDIR/run"
NFQWS_PID_FILE="$RUN_DIR/nfqws2.pid"
WATCHER_PID_FILE="$RUN_DIR/watcher.pid"
SERVICE_LOCK="$RUN_DIR/service.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

stop_pid() {
  local pid_file="$1" name="$2" pid
  [ -f "$pid_file" ] || return 0
  pid=$(cat "$pid_file" 2>/dev/null)
  case "$pid" in ''|0|*[!0-9]*) rm -f "$pid_file"; return 0 ;; esac
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    local n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 3 ]; do sleep 1; n=$((n + 1)); done
    kill -KILL "$pid" 2>/dev/null
    log "Остановлен процесс $name (PID $pid)"
  fi
  rm -f "$pid_file"
}

stop_owned_nfqws() {
  local proc pid cwd n
  for proc in /proc/[0-9]*; do
    [ "$(cat "$proc/comm" 2>/dev/null)" = "nfqws2" ] || continue
    cwd=$(readlink "$proc/cwd" 2>/dev/null)
    [ "$cwd" = "$BIN_DIR" ] || continue
    pid=${proc##*/}
    kill -TERM "$pid" 2>/dev/null
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 3 ]; do sleep 1; n=$((n + 1)); done
    kill -KILL "$pid" 2>/dev/null
    log "Остановлен осиротевший nfqws2 (PID $pid)"
  done
}

cleanup_iptables() {
  while iptables -w 5 -t mangle -D OUTPUT -j ZAPRET2_MANGLE 2>/dev/null; do :; done
  iptables -w 5 -t mangle -F ZAPRET2_MANGLE 2>/dev/null
  iptables -w 5 -t mangle -X ZAPRET2_MANGLE 2>/dev/null
  while iptables -w 5 -t filter -D OUTPUT -j ZAPRET2_FILTER 2>/dev/null; do :; done
  iptables -w 5 -t filter -F ZAPRET2_FILTER 2>/dev/null
  iptables -w 5 -t filter -X ZAPRET2_FILTER 2>/dev/null
  while ip6tables -w 5 -t mangle -D OUTPUT -j ZAPRET2_MANGLE 2>/dev/null; do :; done
  ip6tables -w 5 -t mangle -F ZAPRET2_MANGLE 2>/dev/null
  ip6tables -w 5 -t mangle -X ZAPRET2_MANGLE 2>/dev/null
  while ip6tables -w 5 -t filter -D OUTPUT -j ZAPRET2_FILTER 2>/dev/null; do :; done
  ip6tables -w 5 -t filter -F ZAPRET2_FILTER 2>/dev/null
  ip6tables -w 5 -t filter -X ZAPRET2_FILTER 2>/dev/null
}

get_app_uids() {
  local target_list="$1" app uid uids=""
  [ -f "$target_list" ] || return 0
  while read -r app || [ -n "$app" ]; do
    app=$(echo "$app" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$app" in \#*|'') continue ;; esac
    uid=$(printf '%s\n' "$PACKAGE_UIDS" | grep -F "package:$app uid:" | sed -n 's/.*uid:\([0-9]*\).*/\1/p' | head -n1)
    [ -n "$uid" ] && uids="$uids $uid" || log "Пакет не найден: $app"
  done < "$target_list"
  echo "$uids"
}

if [ "$1" != "reload" ]; then
  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
  sleep 2
fi
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
: "${MODE:=EXCLUDE}" "${STRATEGY_MODE:=AUTO}" "${FORCE_TCP:=1}" "${QUIC_MODE:=SELECTED}" "${PORTS_TCP:=80,443}" "${QNUM:=200}"
PACKAGE_UIDS=$(pm list packages -U 2>/dev/null)
mkdir -p "$RUN_DIR"

# Не допускаем одновременный запуск нескольких reload от WebUI и inotifyd.
lock_attempt=0
while ! mkdir "$SERVICE_LOCK" 2>/dev/null; do
  lock_pid=$(cat "$SERVICE_LOCK/pid" 2>/dev/null)
  case "$lock_pid" in
    ''|0|*[!0-9]*) rm -rf "$SERVICE_LOCK" ;;
    *) kill -0 "$lock_pid" 2>/dev/null || rm -rf "$SERVICE_LOCK" ;;
  esac
  lock_attempt=$((lock_attempt + 1))
  [ "$lock_attempt" -lt 30 ] || { log "Не удалось получить блокировку перезапуска"; exit 1; }
  sleep 1
done
echo $$ > "$SERVICE_LOCK/pid"
release_service_lock() { rm -rf "$SERVICE_LOCK"; }
trap 'release_service_lock; exit 1' HUP INT TERM
trap release_service_lock EXIT

stop_pid "$NFQWS_PID_FILE" "nfqws2"
stop_owned_nfqws
cleanup_iptables

case "$STRATEGY_MODE" in
  AUTO) DESYNC_ARGS="$DESYNC_ARGS_AUTO" ;;
  *) DESYNC_ARGS="$DESYNC_ARGS_SIMPLE" ;;
esac
log "Запуск: MODE=$MODE, стратегия=$STRATEGY_MODE, QUIC_MODE=$QUIC_MODE"

iptables -w 5 -t mangle -N ZAPRET2_MANGLE
iptables -w 5 -t filter -N ZAPRET2_FILTER
ip6tables -w 5 -t mangle -N ZAPRET2_MANGLE 2>/dev/null
ip6tables -w 5 -t filter -N ZAPRET2_FILTER 2>/dev/null

case "$MODE" in
  GLOBAL)
    iptables -w 5 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" --queue-bypass
    ip6tables -w 5 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null ;;
  EXCLUDE)
    for uid in $(get_app_uids "$EXCLUDE_LIST"); do
      iptables -w 5 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -j RETURN
      ip6tables -w 5 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -j RETURN 2>/dev/null
    done
    iptables -w 5 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" --queue-bypass
    ip6tables -w 5 -t mangle -A ZAPRET2_MANGLE -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null ;;
  INCLUDE)
    for uid in $(get_app_uids "$APPS_LIST"); do
      iptables -w 5 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" --queue-bypass
      ip6tables -w 5 -t mangle -A ZAPRET2_MANGLE -m owner --uid-owner "$uid" -p tcp -m multiport --dports "$PORTS_TCP" -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null
    done ;;
  *) log "Недопустимый MODE=$MODE; используется EXCLUDE" ;;
esac
iptables -w 5 -t mangle -A OUTPUT -j ZAPRET2_MANGLE
ip6tables -w 5 -t mangle -A OUTPUT -j ZAPRET2_MANGLE 2>/dev/null

if [ "$FORCE_TCP" = "1" ]; then
  case "$QUIC_MODE" in
    GLOBAL)
      iptables -w 5 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
      ip6tables -w 5 -t filter -A ZAPRET2_FILTER -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null ;;
    SELECTED)
      for uid in $(get_app_uids "$FORCE_TCP_APPS_LIST"); do
        iptables -w 5 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -p udp -j REJECT --reject-with icmp-port-unreachable
        ip6tables -w 5 -t filter -A ZAPRET2_FILTER -m owner --uid-owner "$uid" -p udp -j REJECT --reject-with icmp-port-unreachable 2>/dev/null
      done ;;
  esac
fi
iptables -w 5 -t filter -A OUTPUT -j ZAPRET2_FILTER
ip6tables -w 5 -t filter -A OUTPUT -j ZAPRET2_FILTER 2>/dev/null

HOST_ARGS=""
[ -s "$EXCLUDE_DOMAINS_FILE" ] && HOST_ARGS="$HOST_ARGS --hostlist-exclude=$EXCLUDE_DOMAINS_FILE"
ALT_ARGS=""
if [ -s "$AUTO_DOMAINS_FILE" ] && [ -n "$DESYNC_ARGS_ALT" ]; then
  ALT_ARGS="--new --hostlist=$AUTO_DOMAINS_FILE $DESYNC_ARGS_ALT"
fi
cd "$BIN_DIR" || exit 1
./nfqws2 --user=root --qnum="$QNUM" --bind-fix4 --bind-fix6 \
  --lua-init="@$BIN_DIR/zapret-lib.lua" --lua-init="@$BIN_DIR/zapret-antidpi.lua" --lua-init="@$BIN_DIR/zapret-auto.lua" \
  $HOST_ARGS $DESYNC_ARGS $ALT_ARGS >> "$LOG_FILE" 2>&1 &
echo $! > "$NFQWS_PID_FILE"
sleep 1
nfqws_pid=$(cat "$NFQWS_PID_FILE" 2>/dev/null)
if ! kill -0 "$nfqws_pid" 2>/dev/null; then
  log "Ошибка запуска nfqws2: процесс завершился"
  rm -f "$NFQWS_PID_FILE"
  exit 1
fi

if [ "$1" != "reload" ]; then
  stop_pid "$WATCHER_PID_FILE" "inotifyd"
  if command -v inotifyd >/dev/null 2>&1; then
    inotifyd "$MODDIR/on_change.sh" "$CONF_FILE:w" "$APPS_LIST:w" "$EXCLUDE_LIST:w" "$AUTO_DOMAINS_FILE:w" "$EXCLUDE_DOMAINS_FILE:w" "$FORCE_TCP_APPS_LIST:w" 2>/dev/null &
  elif command -v busybox >/dev/null 2>&1; then
    busybox inotifyd "$MODDIR/on_change.sh" "$CONF_FILE:w" "$APPS_LIST:w" "$EXCLUDE_LIST:w" "$AUTO_DOMAINS_FILE:w" "$EXCLUDE_DOMAINS_FILE:w" "$FORCE_TCP_APPS_LIST:w" 2>/dev/null &
  else
    log "inotifyd не найден: автоматическая перезагрузка списков недоступна"
  fi
  echo $! > "$WATCHER_PID_FILE"
fi
log "Служба запущена: nfqws2 PID $(cat "$NFQWS_PID_FILE")"
