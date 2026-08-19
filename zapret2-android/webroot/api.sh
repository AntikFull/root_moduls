#!/system/bin/sh
# ==============================================================================
# zapret2-android WebUI HTTP / CGI API Bridge
# ==============================================================================

MODDIR="/data/adb/modules/zapret2-android"
CONTROL="$MODDIR/bin/zapret2-control"

# 1. Если аргументы переданы через CLI
if [ $# -gt 0 ]; then
  exec "$CONTROL" "$@"
fi

send_response() {
  _status="$1"
  _body="$2"
  printf "Status: %s\r\n" "$_status"
  printf "Content-Type: application/json; charset=utf-8\r\n"
  printf "Access-Control-Allow-Origin: *\r\n"
  printf "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
  printf "Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With\r\n\r\n"
  if [ -n "$_body" ]; then
    printf "%s\n" "$_body"
  fi
}

if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
  send_response "200 OK" '{"ok":true}'
  exit 0
fi

[ -x "$CONTROL" ] || chmod 0755 "$CONTROL" 2>/dev/null

is_valid_action() {
  case "$1" in
    status|json-status|scope|settings|hotspot-settings|strategies|\
    save-smart|save-strategies|app-lists|apps|app-state|sync-apps|\
    replace-list|diagnostics|nfqws-debug|diag|export-logs|module-version|\
    auto-status|auto-run|auto-clear|webui|warp-status|warp-toggle|\
    warp-sip|warp-rekey|warp-save|restart)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

dispatch_control() {
  _action="$1"
  shift
  if ! is_valid_action "$_action"; then
    send_response "403 Forbidden" "{\"ok\":false,\"error\":\"Запрещённое или неизвестное действие: $_action\"}"
    exit 1
  fi

  _out=$("$CONTROL" "$_action" "$@" 2>&1)
  _rc=$?
  if [ $_rc -eq 0 ]; then
    if [ -n "$_out" ]; then
      send_response "200 OK" "$_out"
    else
      send_response "200 OK" '{"ok":true}'
    fi
  else
    if [ -n "$_out" ]; then
      send_response "500 Internal Server Error" "$_out"
    else
      send_response "500 Internal Server Error" "{\"ok\":false,\"error\":\"Команда завершилась с ошибкой rc=$_rc\"}"
    fi
  fi
  exit $_rc
}

# 2. Обработка GET запросов через QUERY_STRING
if [ -n "$QUERY_STRING" ]; then
  ACTION_VAL=$(echo "$QUERY_STRING" | tr '&' '\n' | grep -m1 '^action=' | cut -d= -f2-)
  CMD_VAL=$(echo "$QUERY_STRING" | tr '&' '\n' | grep -m1 '^cmd=' | cut -d= -f2-)
  C_VAL=$(echo "$QUERY_STRING" | tr '&' '\n' | grep -m1 '^c=' | cut -d= -f2-)

  if [ -n "$ACTION_VAL" ] || [ -n "$C_VAL" ]; then
    RAW_ACT="${ACTION_VAL:-$C_VAL}"
    DEC_ACTION=$(printf '%b' "$(echo "$RAW_ACT" | sed 's/+/ /g; s/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g')" 2>/dev/null)
    [ -n "$DEC_ACTION" ] || DEC_ACTION="$RAW_ACT"

    ARGS_VAL=$(echo "$QUERY_STRING" | tr '&' '\n' | grep -m1 '^args=' | cut -d= -f2-)
    if [ -n "$ARGS_VAL" ]; then
      DEC_ARGS=$(printf '%b' "$(echo "$ARGS_VAL" | sed 's/+/ /g; s/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g')" 2>/dev/null)
      [ -n "$DEC_ARGS" ] || DEC_ARGS="$ARGS_VAL"
      set -- $DEC_ARGS
      dispatch_control "$DEC_ACTION" "$@"
    else
      dispatch_control "$DEC_ACTION"
    fi
  elif [ -n "$CMD_VAL" ]; then
    DEC_CMD=$(printf '%b' "$(echo "$CMD_VAL" | sed 's/+/ /g; s/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g')" 2>/dev/null)
    [ -n "$DEC_CMD" ] || DEC_CMD="$CMD_VAL"

    CLEAN_TOKENS=$(echo "$DEC_CMD" | sed "s|^$CONTROL[[:space:]]*||; s|^zapret2-control[[:space:]]*||; s|^/data/adb/modules/zapret2-android/bin/zapret2-control[[:space:]]*||" | tr "'" " " | tr '"' " ")
    set -- $CLEAN_TOKENS
    if [ $# -gt 0 ]; then
      dispatch_control "$@"
    else
      dispatch_control "json-status"
    fi
  fi
fi

# 3. Обработка POST запросов
if [ "$REQUEST_METHOD" = "POST" ] || [ -n "$CONTENT_LENGTH" ]; then
  BODY=$(head -c 65536 2>/dev/null || cat)
  if [ -n "$BODY" ]; then
    JSON_ACTION=$(echo "$BODY" | sed -n 's/.*"action"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
    JSON_CMD=$(echo "$BODY" | sed -n 's/.*"cmd"[ ]*:[ ]*"\([^"]*\)".*/\1/p')

    if [ -n "$JSON_ACTION" ]; then
      dispatch_control "$JSON_ACTION"
    elif [ -n "$JSON_CMD" ]; then
      CLEAN_TOKENS=$(echo "$JSON_CMD" | sed "s|^$CONTROL[[:space:]]*||; s|^zapret2-control[[:space:]]*||; s|^/data/adb/modules/zapret2-android/bin/zapret2-control[[:space:]]*||; s/\\\\\"//g; s/\\\\//g" | tr "'" " " | tr '"' " ")
      set -- $CLEAN_TOKENS
      if [ $# -gt 0 ]; then
        dispatch_control "$@"
      fi
    fi
  fi
fi

dispatch_control "json-status"