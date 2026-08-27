#!/system/bin/sh
# action.sh — Интерактивный триггер для Action Button (KernelSU / APatch / Magisk)
MODDIR="${0%/*}"
BIN_DIR="$MODDIR/bin"
PROFILES_DIR="/data/adb/amneziawg/profiles"
RUN_DIR="/data/adb/amneziawg/run"

export PATH="$BIN_DIR:$PATH"
export WG_UAPI_DIR="$RUN_DIR"
export AMNEZIAWG_UAPI_DIR="$RUN_DIR"

echo "=== AmneziaWG Multi-Profile Manager ==="

active_cnt="$(ls -1 "$RUN_DIR"/*.pid 2>/dev/null | wc -l)"

if [ "$active_cnt" -gt 0 ]; then
  echo "Активные интерфейсы ($active_cnt):"
  "$BIN_DIR/awg" status
  echo ""
  echo "Перезапуск всех профилей..."
  "$BIN_DIR/awg-controller" restart all
  echo "Профили перезапущены."
else
  echo "Активных интерфейсов нет."
  echo "Запуск включенных профилей..."
  "$BIN_DIR/awg-controller" start all
  echo "Запуск завершен. Текущий статус:"
  "$BIN_DIR/awg" status
fi

echo "========================================"
