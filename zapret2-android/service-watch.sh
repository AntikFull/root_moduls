#!/system/bin/sh

umask 077
MODDIR=${0%/*}
RUN_DIR="$MODDIR/run"
PID_FILE="$RUN_DIR/nfqws2.pid"
LOG_DIR="$MODDIR/logs"
LOG_FILE="$LOG_DIR/zapret2_debug.log"
[ -f "$MODDIR/zapret2.conf" ] && . "$MODDIR/zapret2.conf"
: "${QNUM:=200}" "${HEALTH_WATCH_INTERVAL:=60}"
case "$HEALTH_WATCH_INTERVAL" in ''|*[!0-9]*) HEALTH_WATCH_INTERVAL=60 ;; esac
[ "$HEALTH_WATCH_INTERVAL" -ge 15 ] 2>/dev/null || HEALTH_WATCH_INTERVAL=60
mkdir -p "$RUN_DIR" "$LOG_DIR" 2>/dev/null; chmod 0700 "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] health-watch: $*" >> "$LOG_FILE"; }
pid_is_nfqws() {
  local pid="$1" comm cwd
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(cat "/proc/$pid/comm" 2>/dev/null)
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
  [ "$comm" = nfqws2 ] && [ "$cwd" = "$MODDIR/bin" ]
}

failures=0
while :; do
  sleep "$HEALTH_WATCH_INTERVAL"

  # Настройки меняются из WebUI без полного перезапуска службы. Не держим
  # ENABLE_WARP/WARP_* замороженными с момента загрузки Android.
  [ -f "$MODDIR/zapret2.conf" ] && . "$MODDIR/zapret2.conf"

  # 1. Контроль и самовосстановление WARP туннеля (работает независимо от AntiDPI DIRECT режима)
  if [ "${ENABLE_WARP:-0}" = "1" ] && [ -f "$MODDIR/warp-tunnel.sh" ]; then
    dev="${WARP_DEV:-awg99}"
    if ! ip link show dev "$dev" >/dev/null 2>&1; then
      log "WARP интерфейс $dev не активен; перезапуск туннеля..."
      sh "$MODDIR/warp-tunnel.sh" start >/dev/null 2>&1 || true
    else
      # Проверка здоровья хендшейка и ротация эндпоинтов при необходимости
      sh "$MODDIR/warp-tunnel.sh" watchdog >/dev/null 2>&1 || true
    fi
  fi

  # 2. В режиме DIRECT обход AntiDPI не используется — пропуск проверки nfqws2
  if [ -f "$RUN_DIR/direct.flag" ]; then
    failures=0
    continue
  fi

  # 3. Контроль процесса nfqws2 и очереди NFQUEUE
  pid=$(cat "$PID_FILE" 2>/dev/null)
  ok=1
  case "$pid" in ''|0|*[!0-9]*) ok=0 ;; *) pid_is_nfqws "$pid" || ok=0 ;; esac
  if [ "$ok" = 1 ] && [ -r /proc/net/netfilter/nfnetlink_queue ]; then
    awk -v q="$QNUM" '$1==q {found=1} END{exit !found}' /proc/net/netfilter/nfnetlink_queue 2>/dev/null || ok=0
  fi
  if [ "$ok" = 1 ]; then
    failures=0
    continue
  fi

  failures=$((failures + 1))
  [ "$failures" -ge 2 ] || continue
  log "nfqws2/NFQUEUE дал сбой дважды; перезапуск службы zapret2..."
  rm -f "$RUN_DIR/health-watcher.pid" 2>/dev/null
  exec sh "$MODDIR/service.sh" reload >/dev/null 2>&1
done
