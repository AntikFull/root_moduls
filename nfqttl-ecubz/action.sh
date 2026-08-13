#!/system/bin/sh
MODDIR=${0%/*}

echo "================================================="
echo "   Nfqttl eCubz - РЈРСР°РР»РµРРРµ СРµР¶РРРР РСР»Р°РРР    "
echo "================================================="

if [ -f "$MODDIR/debug" ] || [ -f "$MODDIR/DEBUG" ]; then
    rm -f "$MODDIR/debug" "$MODDIR/DEBUG" 2>/dev/null
    echo "[!] Р РµР¶РР РСР»Р°РРР Р’Р«РљР›Р®Р§Р•Рќ."
    echo "[!] РСР»Р°РРС‡РС‹Р№ Р»РР Р±РР»СЊСРµ РРµ Р±СРРµС Р·Р°РРСС‹РР°ССЊСС."
else
    touch "$MODDIR/debug"
    echo "[+] Р РµР¶РР РСР»Р°РРР Р’РљР›Р®Р§Р•Рќ!"
    echo "[+] Р¤РСРРССС СРРµР¶РР№ РСР»Р°РРС‡РС‹Р№ РСС‡РµС..."
    if [ -f "$MODDIR/debug_log.sh" ]; then
        sh "$MODDIR/debug_log.sh"
    fi
    echo "[+] РСС‡РµС СРС…СР°РРµР Р /data/adb/modules/nfqttl_ecubz/nfqttl_debug.log"
fi

echo "================================================="
