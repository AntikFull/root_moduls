#!/system/bin/sh
# service.sh — поздний запуск сервиса и фоновых мониторов AmneziaWG
MODDIR="${0%/*}"
BIN_DIR="$MODDIR/bin"
PROFILES_DIR="/data/adb/amneziawg/profiles"
LOG_DIR="/data/adb/amneziawg/logs"
LOG_FILE="$LOG_DIR/service.log"

export PATH="$BIN_DIR:$PATH"
export WG_UAPI_DIR="/data/adb/amneziawg/run"
export AMNEZIAWG_UAPI_DIR="/data/adb/amneziawg/run"

mkdir -p "$LOG_DIR" "/data/adb/amneziawg/run" 2>/dev/null

log_s() {
  printf '%s [SERVICE] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

log_s "Инициализация сервиса AmneziaWG Multi-Profile..."

# 1. Ожидание завершения загрузки системы (boot completed)
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 1
done

log_s "Система загружена (sys.boot_completed=1). Ожидание готовности сети..."
sleep 2

# 2. Запуск активных профилей через awg-controller
if [ -x "$BIN_DIR/awg-controller" ]; then
  log_s "Запуск профилей AmneziaWG..."
  "$BIN_DIR/awg-controller" start all >> "$LOG_FILE" 2>&1 &
fi

# 3. Запуск фоновых мониторов через единую точку (setsid, ppid=1)
if [ -f "$BIN_DIR/awg-daemons.sh" ]; then
  # shellcheck disable=SC1090
  . "$BIN_DIR/awg-daemons.sh"
  log_s "Запуск мониторов awg-netmon и awg-appmon..."
  restart_monitors
fi

log_s "Сервис AmneziaWG успешно инициализирован."
