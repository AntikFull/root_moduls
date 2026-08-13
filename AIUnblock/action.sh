#!/system/bin/sh
MODDIR=${0%/*}
CTL="$MODDIR/bin/aiunblockctl"
PUBLIC_LOG_DIR="/sdcard/eCubz/AIUnblock/logs"

echo "AI Unblock: РїСЂРѕРІРµСЂСЏСЋ СЃРѕСЃС‚РѕСЏРЅРёРµ..."
if [ ! -x "$CTL" ]; then
  echo "РћС€РёР±РєР°: РєРѕРјРїРѕРЅРµРЅС‚ РґРёР°РіРЅРѕСЃС‚РёРєРё РѕС‚СЃСѓС‚СЃС‚РІСѓРµС‚."
  exit 1
fi

"$CTL" refresh >/dev/null 2>&1 || true
"$CTL" diag manual

echo "-----------------------------------"
echo "Р“РѕС‚РѕРІРѕ."
echo "РћС‚РїСЂР°РІСЊС‚Рµ РІ РїРѕРґРґРµСЂР¶РєСѓ РїР°РїРєСѓ:"
echo "$PUBLIC_LOG_DIR"
