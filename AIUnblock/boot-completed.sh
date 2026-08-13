#!/system/bin/sh
# Р’СЃС‘, С‡С‚Рѕ С‚СЂРµР±СѓРµС‚ РіРѕС‚РѕРІРѕРіРѕ Android framework, РІС‹РїРѕР»РЅСЏРµРј С‚РѕР»СЊРєРѕ Р·РґРµСЃСЊ.
MODDIR=${0%/*}
[ -f "$MODDIR/lib/locales.sh" ] && . "$MODDIR/lib/locales.sh"
command -v apply_configured_locales >/dev/null 2>&1 && apply_configured_locales "$MODDIR"
# РџСЂРѕРІРµСЂСЏРµРј, СЂРµР°Р»СЊРЅРѕ Р»Рё РїСЂРѕС€РёРІРєР° СЃРјРѕРЅС‚РёСЂРѕРІР°Р»Р° РЅР°С€ optional hosts (Magisk/KSU/APatch
# РґРµР»Р°СЋС‚ СЌС‚Рѕ РїРѕ-СЂР°Р·РЅРѕРјСѓ). Р РµР·СѓР»СЊС‚Р°С‚ РІРёРґРµРЅ РІ aiunblockctl status Рё РІ РѕС‚С‡С‘С‚Рµ.
[ -f "$MODDIR/lib/hosts.sh" ] && . "$MODDIR/lib/hosts.sh"
command -v verify_hosts_overlay >/dev/null 2>&1 && verify_hosts_overlay "$MODDIR"
# Р“Р°СЂР°РЅС‚РёСЂРѕРІР°РЅРЅРѕ РїРµСЂРµС‡РёС‚Р°С‚СЊ UID РїРѕСЃР»Рµ РїРѕСЏРІР»РµРЅРёСЏ PackageManager/work profiles.
touch "$MODDIR/.force_refresh" 2>/dev/null
exit 0
