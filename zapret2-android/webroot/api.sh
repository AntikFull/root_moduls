#!/system/bin/sh
# zapret2-android WebUI HTTP/CGI bridge — argv-only, no eval/shell command parsing.
umask 077
MODDIR="/data/adb/modules/zapret2-android"
[ -x "$MODDIR/bin/zapret2-control" ] || MODDIR="${0%/webroot/api.sh}"
CONTROL="$MODDIR/bin/zapret2-control"
MAX_BODY=65536

# Нативный мост менеджера root (KernelSU / APatch / MMRL) вызывает api.sh
# напрямую с уже разобранным argv — HTTP-слой при этом не участвует, и вызов
# заведомо идёт от процесса с правами root.
if [ $# -gt 0 ]; then
  exec "$CONTROL" "$@"
fi

# Всё, что ниже, — HTTP-путь. Здесь reload обязан быть асинхронным, иначе
# CGI-процесс держит соединение весь перезапуск службы (десятки секунд), и
# WebUI отваливается по таймауту. Прогресс страница читает из json-status.
Z2_ASYNC=1
export Z2_ASYNC

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'; }
send_response() {
  _status="$1"; _body="$2"
  printf 'Status: %s\r\n' "$_status"
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf 'X-Content-Type-Options: nosniff\r\n'
  printf 'Referrer-Policy: no-referrer\r\n\r\n'
  [ -n "$_body" ] && printf '%s\n' "$_body"
}

is_read_action() {
  case "$1" in
    status|json-status|json-connectivity|test-connectivity|json-hotspot-settings|json-strategies|json-diagnostics|json-warp-status|json-hostlist|json-learned|module-version|auto-status|log|nfqws-log) return 0 ;;
    *) return 1 ;;
  esac
}
is_write_action() {
  case "$1" in
    hotspot-settings|save-smart|save-strategies|replace-list|replace-list-b64|nfqws-debug|diag|export-logs|auto-run|auto-clear|warp-toggle|warp-rekey|warp-restart|awg99-restart|awg99-stop|awg99-start|awg98-restart|awg98-stop|awg98-start|awg98-rotate|rotate-geo|restart|service-start|service-stop|start|stop|forcetcp|quicmode|hostlist-mode|hostlist-clear) return 0 ;;
    *) return 1 ;;
  esac
}
is_valid_action() { is_read_action "$1" || is_write_action "$1"; }

urldecode() {
  # Input is data only; percent escapes are decoded without eval.
  _u=$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')
  printf '%b' "$_u" 2>/dev/null
}
param_raw() {
  _name="$1"; _data="$2"
  printf '%s' "$_data" | tr '&' '\n' | sed -n "s/^${_name}=//p" | head -n1
}
param_dec() { _r=$(param_raw "$1" "$2"); [ -n "$_r" ] && urldecode "$_r"; }

dispatch_control() {
  _action="$1"; shift
  if ! is_valid_action "$_action"; then
    send_response '403 Forbidden' "{\"ok\":false,\"error\":\"Недопустимое действие: $(json_escape "$_action")\"}"
    exit 1
  fi
  _out=$("$CONTROL" "$_action" "$@" 2>&1); _rc=$?
  if [ "$_rc" -eq 0 ]; then
    [ -n "$_out" ] && send_response '200 OK' "$_out" || send_response '200 OK' '{"ok":true}'
  else
    [ -n "$_out" ] && send_response '500 Internal Server Error' "$_out" || send_response '500 Internal Server Error' "{\"ok\":false,\"error\":\"rc=$_rc\"}"
  fi
  exit "$_rc"
}

[ -x "$CONTROL" ] || { send_response '500 Internal Server Error' '{"ok":false,"error":"controller unavailable"}'; exit 1; }

METHOD="${REQUEST_METHOD:-GET}"
case "$METHOD" in GET|POST) ;; OPTIONS) send_response '405 Method Not Allowed' '{"ok":false,"error":"CORS disabled"}'; exit 1 ;; *) send_response '405 Method Not Allowed' '{"ok":false,"error":"method"}'; exit 1 ;; esac

DATA="$QUERY_STRING"
if [ "$METHOD" = POST ]; then
  case "${CONTENT_TYPE:-}" in application/x-www-form-urlencoded*) BODY=$(head -c "$MAX_BODY" 2>/dev/null || cat); DATA="$BODY" ;; *) send_response '415 Unsupported Media Type' '{"ok":false,"error":"use application/x-www-form-urlencoded"}'; exit 1 ;; esac
fi
ACTION=$(param_dec action "$DATA")
[ -n "$ACTION" ] || ACTION=json-status

# ------------------------------------------------------------------------------
# Проверка происхождения запроса.
#
# Заголовок-маркер закрывает браузерный cross-origin: сторонняя страница не может
# выставить кастомный заголовок в форме, а fetch к нам блокируется отсутствием CORS.
#
# ЧЕГО ОН НЕ ЗАКРЫВАЕТ: приложение на самом устройстве спокойно выставит любой
# заголовок. Локальный TCP-сокет доступен всем приложениям без единого
# разрешения, и HTTP на localhost в принципе не отличает вызывающего.
# Поэтому настоящая защита — это ENABLE_HTTP_API="0" по умолчанию: у
# KernelSU / APatch / MMRL работает нативный мост выше, и сокет не нужен вовсе.
#
# Маркер требуется и для чтения: json-apps отдаёт полный список установленных
# приложений, а log/nfqws-log — SSID, оператора и UID. Раньше read-команды
# принимались вообще без проверок, так что их забирал любой GET.
# ------------------------------------------------------------------------------
if [ "${HTTP_X_ZAPRET2_WEBUI:-}" != "1" ]; then
  send_response '403 Forbidden' '{"ok":false,"error":"missing WebUI request marker"}'
  exit 1
fi

# Mutations are POST-only. Read-only commands may use GET.
if [ "$METHOD" = GET ] && ! is_read_action "$ACTION"; then
  send_response '405 Method Not Allowed' '{"ok":false,"error":"state-changing actions require POST"}'
  exit 1
fi

# Explicit argv slots preserve spaces/newlines in individual values and never become shell syntax.
a1=$(param_dec arg1 "$DATA"); a2=$(param_dec arg2 "$DATA"); a3=$(param_dec arg3 "$DATA"); a4=$(param_dec arg4 "$DATA")
a5=$(param_dec arg5 "$DATA"); a6=$(param_dec arg6 "$DATA"); a7=$(param_dec arg7 "$DATA"); a8=$(param_dec arg8 "$DATA")
a9=$(param_dec arg9 "$DATA"); a10=$(param_dec arg10 "$DATA"); a11=$(param_dec arg11 "$DATA"); a12=$(param_dec arg12 "$DATA")
ARGC=$(param_dec argc "$DATA"); case "$ARGC" in ''|*[!0-9]*) ARGC=0 ;; esac; [ "$ARGC" -le 12 ] 2>/dev/null || { send_response '400 Bad Request' '{"ok":false,"error":"too many args"}'; exit 1; }

case "$ARGC" in
  0) dispatch_control "$ACTION" ;;
  1) dispatch_control "$ACTION" "$a1" ;;
  2) dispatch_control "$ACTION" "$a1" "$a2" ;;
  3) dispatch_control "$ACTION" "$a1" "$a2" "$a3" ;;
  4) dispatch_control "$ACTION" "$a1" "$a2" "$a3" "$a4" ;;
  5) dispatch_control "$ACTION" "$a1" "$a2" "$a3" "$a4" "$a5" ;;
  6) dispatch_control "$ACTION" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" ;;
  7) dispatch_control "$ACTION" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" ;;
  8) dispatch_control "$ACTION" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8" ;;
  9) dispatch_control "$ACTION" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8" "$a9" ;;
  10) dispatch_control "$ACTION" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8" "$a9" "$a10" ;;
  11) dispatch_control "$ACTION" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8" "$a9" "$a10" "$a11" ;;
  12) dispatch_control "$ACTION" "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7" "$a8" "$a9" "$a10" "$a11" "$a12" ;;
esac
