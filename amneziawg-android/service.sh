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

# 3. Запуск фонового сетевого монитора (awg-netmon)
if [ -x "$BIN_DIR/awg-netmon" ]; then
  log_s "Запуск фонового сетевого монитора awg-netmon..."
  "$BIN_DIR/awg-netmon" >> "$LOG_DIR/netmon.log" 2>&1 &
fi

# 4. Запуск монитора пакетов приложений (awg-appmon)
if [ -x "$BIN_DIR/awg-appmon" ]; then
  log_s "Запуск монитора приложений awg-appmon..."
  "$BIN_DIR/awg-appmon" >> "$LOG_DIR/appmon.log" 2>&1 &
fi

log_s "Сервис AmneziaWG успешно инициализирован."
