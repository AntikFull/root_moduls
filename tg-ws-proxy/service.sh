#!/system/bin/sh
# service.sh - Фоновая служба и супервизор Telegram WS Proxy v1.1.0
# Автор: eCubz (https://t.me/eCubz)

MODDIR="${0%/*}"
case "$MODDIR" in
  /*) ;;
  *)  MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;;
esac
[ -n "$MODDIR" ] || MODDIR="/data/adb/modules/tg-ws-proxy"

export PATH=/system/bin:/system/xbin:/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH

. "$MODDIR/lib.sh"

# 1. Ожидание полной загрузки системы с таймаутом (И1, дефект К5)
wait_for_boot() {
  local timeout=90
  while [ "$timeout" -gt 0 ]; do
    if [ "$(getprop sys.boot_completed)" = "1" ]; then
      return 0
    fi
    sleep 2
    timeout=$((timeout - 2))
  done
  log_msg "WARN" "Таймаут ожидания sys.boot_completed (90c). Продолжаю запуск..."
  return 1
}

wait_for_boot

# Проверка на отключение/удаление модуля
if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
  exit 0
fi

# 2. Инициализация состояния и защита от старых данных после перезагрузки (И2, дефект N3)
reset_stale_state
load_config
ensure_secret
build_args

# 3. Атомарный захват блокировки супервизора (И3, дефект К3)
if ! acquire_lock; then
  log_msg "INFO" "Супервизор уже запущен или заблокирован другим процессом. Выход."
  exit 0
fi

echo $$ > "$SUP_PID_FILE"
trap 'release_lock' EXIT INT TERM

# 4. Первый запуск демона
start_daemon

# 5. Сторожевой цикл супервизора (И1, И4, дефект К6)
FAILS=0
INTERVAL=25

while true; do
  sleep "$INTERVAL"

  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    log_msg "INFO" "Обнаружен флаг disable/remove. Остановка службы."
    stop_daemon
    release_lock
    exit 0
  fi

  DPID="$(daemon_pid)"
  if [ -n "$DPID" ] && is_listening; then
    FAILS=0
    INTERVAL=25
    continue
  fi

  FAILS=$((FAILS + 1))
  log_msg "WARN" "Демон не отвечает на 127.0.0.1:$PORT (сбой #$FAILS)"

  if start_daemon; then
    FAILS=0
    INTERVAL=25
  else
    if [ "$FAILS" -ge 5 ]; then
      if [ "$INTERVAL" -ne 300 ]; then
        log_msg "ERROR" "Превышен лимит сбоев ($FAILS попыток подряд). Переход в замедленный режим проверки (раз в 5 минут)..."
        INTERVAL=300
      fi
    else
      INTERVAL=25
    fi
  fi
done
