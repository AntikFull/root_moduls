#!/system/bin/sh
# action.sh - Интерактивное действие для KernelSU / Magisk / APatch Manager v1.2.0
# Автор: eCubz (https://t.me/eCubz)

MODDIR="${0%/*}"
case "$MODDIR" in
  /*) ;;
  *)  MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd)" ;;
esac
[ -n "$MODDIR" ] || MODDIR="/data/adb/modules/tg-ws-proxy"

export PATH=/system/bin:/system/xbin:/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH

. "$MODDIR/lib.sh"
load_config

CMD="$1"

stop_all() {
  echo "- Остановка службы Telegram WS Proxy..."
  local spid
  spid="$(supervisor_pid)"
  if [ -n "$spid" ]; then
    kill -9 "$spid" 2>/dev/null || true
  fi
  pkill -9 -f "/service.sh" 2>/dev/null || true
  stop_daemon || true
  release_lock || true
  rm -f "$PID_FILE" "$SUP_PID_FILE" "$LINK_FILE"
  echo "  Служба остановлена."
  return 0
}

start_supervisor() {
  local spid
  spid="$(supervisor_pid)"
  if [ -n "$spid" ] && is_listening; then
    echo "  Служба уже работает (PID супервизора: $spid, порт $PORT)."
    return 0
  fi

  echo "- Запуск супервизора через service.sh..."
  release_lock
  sh "$MODDIR/service.sh" >/dev/null 2>&1 &

  local i=0
  while [ "$i" -lt 10 ]; do
    sleep 1
    if is_listening; then
      local dpid
      dpid="$(daemon_pid)"
      echo "  Служба успешно запущена (PID: ${dpid:-?}, порт $PORT)!"
      return 0
    fi
    i=$((i + 1))
  done
  echo "  [!] Служба запускается, но порт $PORT пока не отвечает."
  return 1
}

# Если аргумент не указан (нажатие кнопки Action в менеджере)
if [ -z "$CMD" ]; then
  if pm path io.github.a13e300.ksuwebui >/dev/null 2>&1; then
    echo "- Открываю WebUI в KsuWebUI..."
    am start -n "io.github.a13e300.ksuwebui/.WebUIActivity" -e id "tg-ws-proxy" >/dev/null 2>&1 && exit 0
  elif pm path com.dergoogler.mmrl.wx >/dev/null 2>&1; then
    echo "- Открываю WebUI в MMRL WebUI X..."
    am start -n "com.dergoogler.mmrl.wx/.ui.activity.webui.WebUIActivity" -e MOD_ID "tg-ws-proxy" >/dev/null 2>&1 && exit 0
  fi
  CMD="status"
fi

case "$CMD" in
  stop)
    stop_all
    exit 0
    ;;
  start)
    start_supervisor
    exit 0
    ;;
  restart)
    stop_all
    sleep 1
    start_supervisor
    exit 0
    ;;
  status_json)
    get_status_json
    exit 0
    ;;
  ping)
    echo "- Проверка доступности и задержки Cloudflare-доменов:"
    check_cf_latency
    exit 0
    ;;
  link)
    LINK=""
    [ -f "$LINK_FILE" ] && LINK="$(cat "$LINK_FILE" 2>/dev/null | tr -d '\r\n')"
    [ -z "$LINK" ] && LINK="$(build_link 2>/dev/null)"
    echo "${LINK:-[ERROR] Ссылка недоступна}"
    exit 0
    ;;
  open)
    LINK=""
    [ -f "$LINK_FILE" ] && LINK="$(cat "$LINK_FILE" 2>/dev/null | tr -d '\r\n')"
    [ -z "$LINK" ] && LINK="$(build_link 2>/dev/null)"
    if [ -n "$LINK" ]; then
      am start -a android.intent.action.VIEW -f 0x10000000 \
        ${TG_PACKAGE:+-p "$TG_PACKAGE"} -d "$LINK" >/dev/null 2>&1
      echo "  Окно подключения открыто в Telegram!"
    else
      echo " [!] Не удалось сгенерировать ссылку подключения."
    fi
    exit 0
    ;;
  status|*)
    ;;
esac

echo "=========================================="
echo "         Telegram WS Proxy eCubz          "
echo "=========================================="

SUP_PID="$(supervisor_pid)"
DAEMON_PID="$(daemon_pid)"
LISTENING=0

if is_listening; then
  LISTENING=1
fi

if [ "$LISTENING" = "1" ]; then
  echo " Статус службы:     [ РАБОТАЕТ ]"
  echo " Супервизор PID:    ${SUP_PID:-нет}"
  echo " Демон PID:         ${DAEMON_PID:-нет}"
  echo " Локальный порт:    127.0.0.1:$PORT (ОТКРЫТ)"
  
  # Поиск активного режима/домена в логе
  CF_LINE="$(grep "CF proxy:" "$LOG" 2>/dev/null | tail -n 1)"
  if [ -n "$CF_LINE" ]; then
    echo " Режим/домен CF:    ${CF_LINE#*CF proxy: }"
  fi
else
  echo " Статус службы:     [ НЕ СЛУШАЕТ ПОРТ $PORT ]"
  echo " Супервизор PID:    ${SUP_PID:-нет}"
  echo " Демон PID:         ${DAEMON_PID:-нет}"
  echo " Попытка запуска службы..."
  start_supervisor
fi

echo "------------------------------------------"

if is_listening; then
  LINK=""
  [ -f "$LINK_FILE" ] && LINK="$(cat "$LINK_FILE" 2>/dev/null | tr -d '\r\n')"
  [ -z "$LINK" ] && LINK="$(build_link)"

  if [ -n "$LINK" ]; then
    echo " Ссылка для подключения:"
    echo " $LINK"
    echo "------------------------------------------"
    echo " Открытие диалога в Telegram..."

    AM_OUT="$(am start -a android.intent.action.VIEW -f 0x10000000 \
              ${TG_PACKAGE:+-p "$TG_PACKAGE"} -d "$LINK" 2>&1)"
    case "$AM_OUT" in
      *Error*|*error*|*Exception*)
        echo " -> Не удалось открыть Telegram автоматически."
        echo " -> Скопируйте ссылку выше и отправьте себе в Избранное."
        ;;
      *)
        echo " -> Окно подключения открыто в Telegram!"
        echo " -> Нажмите «Включить» в диалоге."
        ;;
    esac
  else
    echo " [!] Не удалось сгенерировать ссылку подключения."
  fi
else
  echo " [ERROR] Служба не смогла открыться на порту 127.0.0.1:$PORT!"
  echo "------------------------------------------"
  echo " Последние строки основного лога ($LOG):"
  tail -n 8 "$LOG" 2>/dev/null | while IFS= read -r l; do echo "  $l"; done
  if [ -f "$ERRLOG" ]; then
    echo " Ошибки запуска ($ERRLOG):"
    tail -n 5 "$ERRLOG" 2>/dev/null | while IFS= read -r l; do echo "  $l"; done
  fi
fi

echo "=========================================="
