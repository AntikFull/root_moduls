#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"

PUBLIC_DIR="/sdcard/eCubz"
PUBLIC_LOG="$PUBLIC_DIR/${MODULE_ID}_debug.log"

echo "================================================="
echo " $MODULE_NAME"
echo " Версия: $MODULE_VERSION ($MODULE_VERSION_CODE)"
echo "================================================="

if [ -f "$RUNTIME_FILE" ]; then
    MODE4=$(sed -n 's/^MODE4=//p' "$RUNTIME_FILE" | head -1)
    MODE6=$(sed -n 's/^MODE6=//p' "$RUNTIME_FILE" | head -1)
    echo " IPv4: ${MODE4:-unknown}"
    echo " IPv6: ${MODE6:-unknown}"
    _cb=$(sed -n 's/^CARRIER_PROVISIONING_BYPASS=//p' "$RUNTIME_FILE" | head -1)
    echo " Carrier provisioning bypass: ${_cb:-unknown}"
else
    echo " Runtime status: ещё не создан"
fi

if [ -f "$MODDIR/debug" ] || [ -f "$MODDIR/DEBUG" ]; then
    rm -f "$MODDIR/debug" "$MODDIR/DEBUG" 2>/dev/null || true
    echo ""
    echo "[-] Расширенный debug-режим выключен."
    echo "    Обычный service.log продолжает вестись."
else
    touch "$MODDIR/debug"
    echo ""
    echo "[+] Расширенный debug-режим включён."
    echo "[+] Собираю свежий диагностический отчёт..."
    if [ -x "$MODDIR/debug_log.sh" ]; then
        sh "$MODDIR/debug_log.sh"
        if [ -f "$PUBLIC_LOG" ]; then
            echo "[+] Отчёт: $PUBLIC_LOG"
        else
            echo "[!] Публичная копия недоступна; внутренняя: $LOG_DIR/${MODULE_ID}_debug.log"
        fi
    else
        echo "[!] debug_log.sh отсутствует или не исполняемый."
    fi
fi

echo "================================================="
