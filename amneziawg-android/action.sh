#!/system/bin/sh
# action.sh — Кнопка Действие в менеджере root: перезапуск демонов и вывод статуса
MODDIR="${0%/*}"
BIN_DIR="$MODDIR/bin"
LOG_DIR="/data/adb/amneziawg/logs"
RUN_DIR="/data/adb/amneziawg/run"

mkdir -p "$LOG_DIR" "$RUN_DIR" 2>/dev/null

# shellcheck disable=SC1090
. "$BIN_DIR/awg-daemons.sh"

echo "=== AWG eCubz ==="

restart_monitors
echo "Мониторы перезапущены: awg-netmon, awg-appmon"

# Явный вызов пользователем снимает блокировку watchdog со всех профилей
"$BIN_DIR/awg-controller" reset-failures all >/dev/null 2>&1

active_cnt="$(ls -1 "$RUN_DIR"/*.iface 2>/dev/null | wc -l)"
if [ "$active_cnt" -gt 0 ]; then
  echo "Активных профилей: $active_cnt. Синхронизация правил..."
  "$BIN_DIR/awg-controller" sync-rules >/dev/null 2>&1
else
  echo "Активных профилей нет. Запуск включенных..."
  "$BIN_DIR/awg-controller" start all >/dev/null 2>&1
fi

echo ""
"$BIN_DIR/awg" status
echo "================="
