#!/system/bin/sh
# ==============================================================================
# zapret2-android WebUI HTTP / CGI API Bridge
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

# Функция выполнения команды
run_control() {
  _cmd="$1"
  # Удаляем префикс вызова zapret2-control если он есть
  _cmd=$(echo "$_cmd" | sed "s|^$CONTROL[[:space:]]*||; s|^zapret2-control[[:space:]]*||; s|^/data/adb/modules/zapret2-android/bin/zapret2-control[[:space:]]*||; s|^['\"]*||; s|['\"]*$||")
  if [ -n "$_cmd" ]; then
    _out=$(eval "$CONTROL $_cmd" 2>&1)
    _rc=$?
    if [ -n "$_out" ]; then
      printf "%s\n" "$_out"
    else
      printf '{"ok":true}\n'
    fi
    exit $_rc
  else
    exec "$CONTROL" json-status
  fi
}

# 2. Обработка GET запросов через QUERY_STRING
if [ -n "$QUERY_STRING" ]; then
  # 2.1 Извлечение action=...
  ACTION_VAL=$(echo "$QUERY_STRING" | tr '&' '\n' | grep -m1 '^action=' | cut -d= -f2-)
  # 2.2 Извлечение cmd=...
  CMD_VAL=$(echo "$QUERY_STRING" | tr '&' '\n' | grep -m1 '^cmd=' | cut -d= -f2-)
  # 2.3 Извлечение c=...
  C_VAL=$(echo "$QUERY_STRING" | tr '&' '\n' | grep -m1 '^c=' | cut -d= -f2-)

  CHOSEN="${ACTION_VAL:-${CMD_VAL:-$C_VAL}}"
  if [ -n "$CHOSEN" ]; then
    # Быстрое декодирование URL
    DECODED=$(printf '%b' "$(echo "$CHOSEN" | sed 's/+/ /g; s/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g')" 2>/dev/null)
    [ -n "$DECODED" ] || DECODED="$CHOSEN"
    run_control "$DECODED"
  fi
fi

# 3. Обработка POST запросов
if [ "$REQUEST_METHOD" = "POST" ] || [ -n "$CONTENT_LENGTH" ]; then
  BODY=$(cat)
  if [ -n "$BODY" ]; then
    JSON_ACTION=$(echo "$BODY" | sed -n 's/.*"action"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
    JSON_CMD=$(echo "$BODY" | sed -n 's/.*"cmd"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
    
    TARGET="${JSON_ACTION:-$JSON_CMD}"
    [ -n "$TARGET" ] || TARGET="$BODY"
    
    CLEAN_TARGET=$(echo "$TARGET" | sed 's/\\"/"/g; s/\\\//\//g')
    run_control "$CLEAN_TARGET"
  fi
fi

exec "$CONTROL" json-status