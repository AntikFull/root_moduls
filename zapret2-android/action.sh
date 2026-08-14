#!/system/bin/sh
umask 077

MODDIR="${0%/*}"
CONTROL="$MODDIR/bin/zapret2-control"

echo "Перезапуск Zapret2 eCubz..."
sh "$MODDIR/service.sh" reload
sleep 1
if [ -x "$CONTROL" ]; then
  echo ""
  "$CONTROL" status
  echo ""
  echo "Если health не OK: открывать WebUI -> Диагностика -> Запустить диагностику."
fi
echo "WebUI открывается через страницу модуля в KernelSU Next; HTTP-сервер не требуется."
