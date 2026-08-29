#!/system/bin/sh
# service.sh — поздний запуск сервиса и фоновых мониторов AmneziaWG
MODDIR="${0%/*}"
BIN_DIR="$MODDIR/bin"
PROFILES_DIR="/data/adb/amneziawg/profiles"
LOG_DIR="/data/adb/amneziawg/logs"
LOG_FILE="$LOG_DIR/service.log"

export PATH="/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$BIN_DIR:/system/bin:/system/xbin:/apex/com.android.runtime/bin:$PATH"
export WG_UAPI_DIR="/data/adb/amneziawg/run"
export AMNEZIAWG_UAPI_DIR="/data/adb/amneziawg/run"

mkdir -p "$LOG_DIR" "/data/adb/amneziawg/run" 2>/dev/null # глушение-обосновано: каталоги создаются в post-fs-data и обычно уже существуют

log_s() {
  printf '%s [SERVICE] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

log_s "Инициализация сервиса AmneziaWG Multi-Profile..."

# 1. Ожидание завершения загрузки системы (boot completed).
# Ограничение по времени обязательно: на части прошивок sys.boot_completed
# не выставляется никогда, и безусловный цикл оставлял бы процесс висеть
# в памяти до перезагрузки, так и не подняв туннели.
BOOT_WAIT_MAX=180
boot_waited=0
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 1
  boot_waited=$((boot_waited + 1))
  if [ "$boot_waited" -ge "$BOOT_WAIT_MAX" ]; then
    log_s "sys.boot_completed не выставлен за $BOOT_WAIT_MAX c. Запуск выполняется без него."
    break
  fi
done

log_s "Система загружена (ожидание: $boot_waited c). Пауза на готовность сети..."
sleep 2

chmod 755 "$BIN_DIR"/* 2>/dev/null || true # глушение-обосновано: на части прошивок раздел модуля монтируется только для чтения

# 2. Запуск активных профилей.
# Порядок важен: профили поднимаются ДО мониторов. Прежняя редакция сначала
# запускала awg-netmon, который немедленно выполняет sync-rules и тоже
# поднимает профили, из-за чего два процесса одновременно занимали один слот
# интерфейса. Команда start берет общий лок состояния и выполняется синхронно.
if [ -x "$BIN_DIR/awg-controller" ]; then
  log_s "Запуск профилей AmneziaWG..."
  "$BIN_DIR/awg-controller" start all >> "$LOG_FILE" 2>&1 || \
    log_s "Запуск профилей завершился с ошибкой, подробности выше."
fi

# 3. Запуск фоновых мониторов через единую точку (setsid, ppid=1)
if [ -f "$BIN_DIR/awg-daemons.sh" ]; then
  # shellcheck disable=SC1090
  . "$BIN_DIR/awg-daemons.sh"
  log_s "Запуск мониторов awg-netmon и awg-appmon..."
  restart_monitors || log_s "Мониторы не стартовали: watchdog не работает."
fi

log_s "Сервис AmneziaWG успешно инициализирован."
