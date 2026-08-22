#!/system/bin/sh
umask 077

MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;; esac
CONTROL="$MODDIR/bin/zapret2-control"

echo "Перезапуск Zapret2 eCubz..."
sh "$MODDIR/service.sh" reload
sleep 1
if [ -x "$CONTROL" ]; then
  echo ""
  "$CONTROL" status
  echo ""
  echo "Если health не OK: WebUI -> Диагностика -> Запустить диагностику."
fi

echo ""
echo "WebUI: страница модуля в KernelSU / APatch / MMRL (нативный мост, ничего включать не нужно)."
http_api=$(sed -n 's/^ENABLE_HTTP_API="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$MODDIR/zapret2.conf" 2>/dev/null | head -n1)
if [ "$http_api" = "1" ]; then
  port=$(cat "$MODDIR/run/webui.port" 2>/dev/null)
  case "$port" in ''|*[!0-9]*) port="" ;; esac
  if [ -n "$port" ]; then
    echo "HTTP API включён: http://127.0.0.1:$port/ (только с этого телефона)."
  else
    echo "HTTP API включён в конфиге, но сервер не поднялся — см. logs/zapret2_debug.log."
  fi
else
  echo "Доступ из браузера выключен. Включить: ENABLE_HTTP_API=\"1\" в zapret2.conf + перезапуск."
fi
