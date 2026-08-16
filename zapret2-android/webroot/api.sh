#!/system/bin/sh
# ==============================================================================
# zapret2-android WebUI HTTP / CGI API Bridge
# ==============================================================================
# Позволяет WebUI работать в Webroot Manager (OpenResty), Magisk, MMRL
# и обычных браузерах (http://localhost:8080/zapret2-android/)
# ==============================================================================

MODDIR="/data/adb/modules/zapret2-android"
CONTROL="$MODDIR/bin/zapret2-control"

# HTTP заголовки ответа
printf "Status: 200 OK\r\n"
printf "Content-Type: application/json; charset=utf-8\r\n"
printf "Access-Control-Allow-Origin: *\r\n"
printf "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
printf "Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With\r\n\r\n"

if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
  exit 0
fi

[ -x "$CONTROL" ] || chmod 0755 "$CONTROL" 2>/dev/null

# 1. Если аргументы переданы через CLI
if [ $# -gt 0 ]; then
  exec "$CONTROL" "$@"
fi

# 2. Обработка GET запросов через QUERY_STRING
if [ -n "$QUERY_STRING" ]; then
  CMD_VAL=$(echo "$QUERY_STRING" | sed -n 's/.*[?&]*\(cmd\|action\|c\)=\([^&]*\).*/\2/p')
  if [ -n "$CMD_VAL" ]; then
    DECODED_CMD=$(printf '%b' "$(echo "$CMD_VAL" | sed 's/%/\\x/g')" 2>/dev/null)
    [ -n "$DECODED_CMD" ] || DECODED_CMD="$CMD_VAL"
    
    if echo "$DECODED_CMD" | grep -q "zapret2-control"; then
      eval "$DECODED_CMD"
      exit $?
    fi
    
    ARGS_VAL=$(echo "$QUERY_STRING" | sed -n 's/.*[?&]*args=\([^&]*\).*/\1/p')
    if [ -n "$ARGS_VAL" ]; then
      DECODED_ARGS=$(printf '%b' "$(echo "$ARGS_VAL" | sed 's/%/\\x/g')" 2>/dev/null)
      [ -n "$DECODED_ARGS" ] || DECODED_ARGS="$ARGS_VAL"
      exec "$CONTROL" $DECODED_CMD $DECODED_ARGS
    else
      exec "$CONTROL" $DECODED_CMD
    fi
  fi
fi

# 3. Обработка POST запросов
if [ "$REQUEST_METHOD" = "POST" ] || [ -n "$CONTENT_LENGTH" ]; then
  BODY=$(cat)
  if [ -n "$BODY" ]; then
    JSON_CMD=$(echo "$BODY" | sed -n 's/.*"cmd"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
    JSON_ACTION=$(echo "$BODY" | sed -n 's/.*"action"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
    
    if [ -n "$JSON_CMD" ]; then
      CLEAN_CMD=$(echo "$JSON_CMD" | sed 's/\\"/"/g; s/\\\//\//g')
      eval "$CLEAN_CMD"
      exit $?
    elif [ -n "$JSON_ACTION" ]; then
      exec "$CONTROL" $JSON_ACTION
    else
      if echo "$BODY" | grep -q "zapret2-control"; then
        eval "$BODY"
        exit $?
      else
        exec "$CONTROL" $BODY
      fi
    fi
  fi
fi

exec "$CONTROL" json-status