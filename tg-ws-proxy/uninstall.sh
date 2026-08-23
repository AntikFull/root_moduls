#!/system/bin/sh
# uninstall.sh - Очистка процессов и состояния при удалении Telegram WS Proxy v1.1.0
# Автор: eCubz (https://t.me/eCubz)

MODDIR="${0%/*}"
case "$MODDIR" in
  /*) ;;
  *)  MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;;
esac
[ -n "$MODDIR" ] || MODDIR="/data/adb/modules/tg-ws-proxy"

export PATH=/system/bin:/system/xbin:/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH

if [ -f "$MODDIR/lib.sh" ]; then
  . "$MODDIR/lib.sh"
else
  STATE="/data/adb/tg-ws-proxy"
fi

touch "$MODDIR/disable" 2>/dev/null

# 1. Остановка подтверждённого супервизора
if [ -n "$SUP_PID_FILE" ] && [ -f "$SUP_PID_FILE" ]; then
  spid="$(cat "$SUP_PID_FILE" 2>/dev/null | tr -d '\r\n ')"
  if [ -n "$spid" ] && [ -d "/proc/$spid" ]; then
    if tr '\0' ' ' < "/proc/$spid/cmdline" 2>/dev/null | grep -q "service.sh"; then
      kill "$spid" 2>/dev/null
    fi
  fi
fi

# 2. Остановка подтверждённого демона
if [ -n "$PID_FILE" ] && [ -f "$PID_FILE" ]; then
  dpid="$(cat "$PID_FILE" 2>/dev/null | tr -d '\r\n ')"
  if [ -n "$dpid" ] && [ -d "/proc/$dpid" ]; then
    if tr '\0' ' ' < "/proc/$dpid/cmdline" 2>/dev/null | grep -q "tg-ws-proxy"; then
      kill "$dpid" 2>/dev/null
    fi
  fi
fi

killall tg-ws-proxy 2>/dev/null

# 3. Безопасное удаление runtime-состояния и каталога /data/adb/tg-ws-proxy
case "$STATE" in
  /data/adb/tg-ws-proxy)
    rm -rf "$STATE"
    ;;
  *)
    ;;
esac
