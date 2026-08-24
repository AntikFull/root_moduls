#!/system/bin/sh
# ==============================================================================
# service-watch.sh — сторож службы.
#   1. Самовосстановление туннеля WARP.
#   2. Контроль процесса nfqws2 и привязки очереди NFQUEUE.
#   3. Обнаружение изменений конфигурации, пропущенных inotify.
# ==============================================================================
umask 077
MODDIR=${0%/*}
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
RUN_DIR="$MODDIR/run"
PID_FILE="$RUN_DIR/nfqws2.pid"
LOG_DIR="$MODDIR/logs"
LOG_FILE="$LOG_DIR/zapret2_debug.log"
CONF_FILE="$MODDIR/zapret2.conf"
LISTS_DIR="$MODDIR/lists"
[ -d "$LISTS_DIR" ] || LISTS_DIR="$MODDIR"
STRATEGY_DIR="$MODDIR/strategies"
CONFIG_SIG_FILE="$RUN_DIR/config.sig"
CONTROL_WRITE_MARK="$RUN_DIR/control-write.ts"
STRATEGY_LIB="$MODDIR/strategy-lib.sh"
[ -f "$STRATEGY_LIB" ] && . "$STRATEGY_LIB"

[ -f "$CONF_FILE" ] && . "$CONF_FILE"
: "${QNUM:=200}" "${HEALTH_WATCH_INTERVAL:=60}" "${CONFIG_DRIFT_CHECK:=1}" "${HEALTH_ERROR_BACKOFF:=600}"
case "$HEALTH_ERROR_BACKOFF" in ''|*[!0-9]*) HEALTH_ERROR_BACKOFF=600 ;; esac
case "$HEALTH_WATCH_INTERVAL" in ''|*[!0-9]*) HEALTH_WATCH_INTERVAL=60 ;; esac
[ "$HEALTH_WATCH_INTERVAL" -ge 15 ] 2>/dev/null || HEALTH_WATCH_INTERVAL=60
mkdir -p "$RUN_DIR" "$LOG_DIR" 2>/dev/null; chmod 0700 "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true
# Зомби и умирающие процессы не отдают cmdline: ядро держит блокировку памяти
# задачи, и чтение виснет без таймаута — однажды это подвесило перезапуск целиком.
# /proc/PID/stat читается без этой блокировки, поэтому сначала спрашиваем
# состояние. Полный вариант с потолком по времени — в service.sh.
pid_cmdline() {
  local st
  case "$1" in ''|0|*[!0-9]*) return 1 ;; esac
  st=$(sed -n 's/.*) //p' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)
  case "$st" in ''|Z|X|x) return 1 ;; esac
  tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] health-watch: $2" >> "$LOG_FILE"; }

pid_is_nfqws() {
  local pid="$1" comm cwd cmd
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(cat "/proc/$pid/comm" 2>/dev/null)
  [ "$comm" = nfqws2 ] || return 1
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
  [ "$cwd" = "$MODDIR/bin" ] || return 1
  # Тестовый процесс auto-select работает на другой очереди — он не наш.
  cmd=$(pid_cmdline "$pid")
  case " $cmd " in *" --qnum=$QNUM "*) return 0 ;; *) return 1 ;; esac
}

# Та же формула, что и в service.sh::config_signature — файлы и порядок обязаны
# совпадать, иначе подписи разойдутся и watcher уйдёт в цикл перезагрузок.

# Реконсиляция идёт прямо сейчас. Замерено на устройстве: полный reload длится
# 45-90 секунд, а окно control_write_recent — 15. Всё это время конфиг уже
# новый, а run/config.sig ещё старый, и дрейф-проверка честно видит расхождение
# и запускает ВТОРОЙ reload поверх первого. Наличие живого владельца
# service.lock — точный признак того, что расхождение вот-вот закроется само.
service_reload_running() {
  local pid
  pid=$(cat "$RUN_DIR/service.lock/pid" 2>/dev/null)
  case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# Служба уже упала на этом старте (нет NFQUEUE, nfqws2 не поднялся). Сторож
# теперь переживает такую аварию — но дёргать reload каждые две минуты на
# заведомо несовместимом ядре смысла нет. Отступаем на HEALTH_ERROR_BACKOFF.
startup_failed_recently() {
  local state ts now age
  state=$(sed -n 's/^STATE=//p' "$RUN_DIR/startup.env" 2>/dev/null | head -n1)
  [ "$state" = ERROR ] || return 1
  ts=$(sed -n 's/^UPDATED=//p' "$RUN_DIR/startup.env" 2>/dev/null | head -n1)
  now=$(date +%s 2>/dev/null)
  case "$ts:$now" in *[!0-9:]*|:*) return 1 ;; esac
  age=$((now - ts))
  [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -lt "${HEALTH_ERROR_BACKOFF:-600}" ] 2>/dev/null
}

# Запись, сделанная контроллером, уже применена им самим.
control_write_recent() {
  local ts now age
  ts=$(cat "$CONTROL_WRITE_MARK" 2>/dev/null)
  now=$(date +%s 2>/dev/null)
  case "$ts:$now" in *[!0-9:]*|:*) return 1 ;; esac
  age=$((now - ts))
  [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -le 15 ] 2>/dev/null
}

failures=0
while :; do
  sleep "$HEALTH_WATCH_INTERVAL"

  # Если служба остановлена пользователем — не перезапускать ничего
  if [ -f "$RUN_DIR/service_stopped.flag" ]; then
    failures=0
    continue
  fi

  # 1. Контроль и самовосстановление туннелей (WARP AWG99 и Geo AWG98).
  if { [ "${ENABLE_WARP:-0}" = "1" ] || [ "${ENABLE_GEO_WARP:-1}" = "1" ]; } && [ -f "$MODDIR/warp-tunnel.sh" ]; then
    dev="${WARP_DEV:-awg99}"
    geo_dev="${GEO_DEV:-awg98}"
    need_start=0
    if [ "${ENABLE_WARP:-0}" = "1" ] && [ ! -f "$RUN_DIR/warp_stopped.flag" ] && ! ip link show dev "$dev" >/dev/null 2>&1; then
      need_start=1
    fi
    if [ "${ENABLE_GEO_WARP:-1}" = "1" ] && [ ! -f "$RUN_DIR/geo_stopped.flag" ] && ! ip link show dev "$geo_dev" >/dev/null 2>&1; then
      need_start=1
    fi

    if [ "$need_start" = 1 ]; then
      warp_lock_pid=$(cat "$RUN_DIR/warp.lock/pid" 2>/dev/null)
      case "$warp_lock_pid" in
        ''|0|*[!0-9]*) warp_lock_pid="" ;;
        *) kill -0 "$warp_lock_pid" 2>/dev/null || warp_lock_pid="" ;;
      esac
      if [ -n "$warp_lock_pid" ]; then
        log INFO "Туннели: подъём уже выполняется (PID $warp_lock_pid), тик пропущен"
      else
        log WARN "Интерфейс туннеля не активен; запуск восстановления в фоне"
        sh "$MODDIR/warp-tunnel.sh" start >/dev/null 2>&1 &
      fi
    else
      sh "$MODDIR/warp-tunnel.sh" watchdog >/dev/null 2>&1 || true
    fi
  fi

  # 2. Дрейф конфигурации: правка в обход inotify (adb push, файловый менеджер,
  #    атомарная замена файла сторонним редактором).
  if [ "$CONFIG_DRIFT_CHECK" = "1" ] && [ -s "$CONFIG_SIG_FILE" ] && ! control_write_recent && ! service_reload_running; then
    current_sig=$(config_signature)
    stored_sig=$(cat "$CONFIG_SIG_FILE" 2>/dev/null)
    if [ -n "$current_sig" ] && [ "$current_sig" != "$stored_sig" ]; then
      log INFO "конфигурация изменена вне вотчера ($stored_sig -> $current_sig); реконсиляция"
      rm -f "$RUN_DIR/health-watcher.pid" 2>/dev/null
      exec sh "$MODDIR/service.sh" reload >/dev/null 2>&1
    fi
  fi

  # 3. В режиме DIRECT обход не используется — nfqws2 отсутствует штатно.
  if [ -f "$RUN_DIR/direct.flag" ]; then
    failures=0
    continue
  fi

  # 4. Контроль процесса nfqws2 и очереди NFQUEUE.
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
  if startup_failed_recently; then
    log INFO "nfqws2 отсутствует, но предыдущий старт завершился ошибкой; повтор отложен"
    failures=0
    continue
  fi
  log WARN "nfqws2/NFQUEUE дал сбой дважды подряд; перезапуск службы"
  rm -f "$RUN_DIR/health-watcher.pid" 2>/dev/null
  exec sh "$MODDIR/service.sh" reload >/dev/null 2>&1
done
