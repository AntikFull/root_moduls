#!/system/bin/sh
umask 077
# Action: безопасный перезапуск и краткая самодиагностика.

MODDIR="${0%/*}"
CONTROL="$MODDIR/bin/zapret2-control"

echo "Перезапуск Zapret2 eCubz..."
sh "$MODDIR/service.sh" reload
sleep 1
if [ -x "$CONTROL" ]; then
  echo ""
  "$CONTROL" status
  echo ""
  echo "Если health не OK: WebUI -> Диагностика -> Собрать диагностику."
fi
echo "WebUI открывается штатно со страницы модуля в KernelSU Next; HTTP-сервер не используется."
