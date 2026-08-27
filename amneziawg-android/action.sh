#!/system/bin/sh
# action.sh — Перезапуск демонов при вызове кнопки Действие в менеджере рута
MODDIR="${0%/*}"

pkill -f awg-netmon 2>/dev/null || true
pkill -f awg-appmon 2>/dev/null || true
nohup "$MODDIR/bin/awg-netmon" >/dev/null 2>&1 &
nohup "$MODDIR/bin/awg-appmon" >/dev/null 2>&1 &
"$MODDIR/bin/awg-controller" sync-rules >/dev/null 2>&1
