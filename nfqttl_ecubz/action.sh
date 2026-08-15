#!/system/bin/sh
MODDIR=${0%/*}

echo "================================================="
echo "   Nfqttl eCubz — Управление режимом отладки    "
echo "================================================="

if [ -f "$MODDIR/debug" ] || [ -f "$MODDIR/DEBUG" ]; then
    rm -f "$MODDIR/debug" "$MODDIR/DEBUG" 2>/dev/null
    echo "[!] Режим отладки ВЫКЛЮЧЕН."
    echo "[!] Отладочный лог больше не будет записываться."
else
    touch "$MODDIR/debug"
    echo "[+] Режим отладки ВКЛЮЧЕН!"
    echo "[+] Формирую свежий отладочный отчет..."
    if [ -f "$MODDIR/debug_log.sh" ]; then
        sh "$MODDIR/debug_log.sh"
    fi
    echo "[+] Отчет сохранен в $MODDIR/logs/nfqttl_debug.log"
    echo "[+] Копия доступна в /sdcard/eCubz/logs/nfqttl_ecubz/nfqttl_debug.log"
fi

echo "================================================="
