#!/system/bin/sh
MODDIR=${0%/*}

# ============================================================================
# Nfqttl eCubz Action Script for KernelSU / Magisk / APatch
# ============================================================================

echo "================================================="
echo "   Nfqttl eCubz - Управление режимом отладки    "
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
    echo "[+] Отчет сохранен в /data/adb/modules/nfqttl_ecubz/nfqttl_debug.log"
fi

echo "================================================="
