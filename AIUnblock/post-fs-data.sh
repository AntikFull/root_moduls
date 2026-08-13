#!/system/bin/sh
# Р’С‹РїРѕР»РЅСЏРµС‚СЃСЏ Р”Рћ mount stage: Р·РґРµСЃСЊ Р±РµР·РѕРїР°СЃРЅРѕ СѓР±СЂР°С‚СЊ optional system/ РїСЂРё РєРѕРЅС„Р»РёРєС‚Рµ.
MODDIR=${0%/*}
[ -f "$MODDIR/lib/hosts.sh" ] || exit 0
. "$MODDIR/lib/hosts.sh"
prepare_hosts_tree "$MODDIR" || rm -rf "$MODDIR/system" 2>/dev/null
exit 0
