#!/system/bin/sh
MODDIR=${0%/*}

echo "================================================="
echo "   Nfqttl eCubz - РРСРРРРРРР СРРРРРР РСРРРРР    "
echo "================================================="

if [ -f "$MODDIR/debug" ] || [ -f "$MODDIR/DEBUG" ]; then
    rm -f "$MODDIR/debug" "$MODDIR/DEBUG" 2>/dev/null
    echo "[!] РРРРР РСРРРРР РРРРРРРР."
    echo "[!] РСРРРРСРСР РРР РРРССР РР РСРРС РРРРССРРСССС."
else
    touch "$MODDIR/debug"
    echo "[+] РРРРР РСРРРРР РРРРРРР!"
    echo "[+] РРСРРССС СРРРРР РСРРРРСРСР РССРС..."
    if [ -f "$MODDIR/debug_log.sh" ]; then
        sh "$MODDIR/debug_log.sh"
    fi
    echo "[+] РССРС СРССРРРР Р /data/adb/modules/nfqttl_ecubz/nfqttl_debug.log"
fi

echo "================================================="
