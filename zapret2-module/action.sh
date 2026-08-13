#!/system/bin/sh
umask 077
# Action: Р±РµР·РѕРїР°СЃРЅС‹Р№ РїРµСЂРµР·Р°РїСѓСЃРє Рё РєСЂР°С‚РєР°СЏ СЃР°РјРѕРґРёР°РіРЅРѕСЃС‚РёРєР°.

MODDIR="${0%/*}"
CONTROL="$MODDIR/bin/zapret2-control"

echo "РџРµСЂРµР·Р°РїСѓСЃРє Zapret2 eCubz..."
sh "$MODDIR/service.sh" reload
sleep 1
if [ -x "$CONTROL" ]; then
  echo ""
  "$CONTROL" status
  echo ""
  echo "Р•СЃР»Рё health РЅРµ OK: WebUI -> Р”РёР°РіРЅРѕСЃС‚РёРєР° -> РЎРѕР±СЂР°С‚СЊ РґРёР°РіРЅРѕСЃС‚РёРєСѓ."
fi
echo "WebUI РѕС‚РєСЂС‹РІР°РµС‚СЃСЏ С€С‚Р°С‚РЅРѕ СЃРѕ СЃС‚СЂР°РЅРёС†С‹ РјРѕРґСѓР»СЏ РІ KernelSU Next; HTTP-СЃРµСЂРІРµСЂ РЅРµ РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ."
