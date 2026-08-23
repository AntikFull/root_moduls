#!/system/bin/sh
# lib.sh — общая библиотека функций Telegram WS Proxy v1.2.0
# Автор: eCubz (https://t.me/eCubz)

MOD_ID="tg-ws-proxy"
STATE="/data/adb/$MOD_ID"
CONF_FILE="$STATE/config.conf"
SECRET_FILE="$STATE/secret.conf"
LOG_DIR="$STATE/logs"
LOG="$LOG_DIR/tg-ws-proxy.log"
ERRLOG="$LOG_DIR/stderr.log"
RUN_DIR="$STATE/run"
PID_FILE="$RUN_DIR/daemon.pid"
SUP_PID_FILE="$RUN_DIR/supervisor.pid"
LOCK_DIR="$RUN_DIR/supervisor.lock"
LINK_FILE="$RUN_DIR/proxy_link.txt"
BOOT_ID_FILE="$RUN_DIR/boot.id"
HEALTH_FILE="$RUN_DIR/health.env"
BIN="$MODDIR/bin/tg-ws-proxy"
export SSL_CERT_DIR="/system/etc/security/cacerts:/apex/com.android.conscrypt/cacerts"

# Разрешение абсолютного пути MODDIR
resolve_moddir() {
  local src="$1"
  local d="${src%/*}"
  case "$d" in
    /*) echo "$d" ;;
    *)  echo "$(cd "$d" 2>/dev/null && pwd || echo "/data/adb/modules/tg-ws-proxy")" ;;
  esac
}

# Логирование в основной лог модуля
log_msg() {
  local level="$1"
  shift
  mkdir -p "$LOG_DIR" 2>/dev/null
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG"
}

# Загрузка и валидация конфигурации
load_config() {
  HOST="127.0.0.1"
  PORT="1443"
  SECRET=""
  FAKE_TLS_DOMAIN=""
  CFPROXY_DOMAINS=""
  CFPROXY_DOMAINS_URL="https://raw.githubusercontent.com/spatiumstas/tg-ws-proxy-go/main-go/.github/cfproxy-domains.txt"
  CFPROXY_WORKER_DOMAIN=""
  CFPROXY_PRIORITY="0"
  POOL_SIZE="1"
  BUF_KB="64"
  MAX_CONNS="256"
  LOG_MAX_MB="2"
  LOG_BACKUPS="1"
  VERBOSE="0"
  EXTRA_ARGS=""
  TG_PACKAGE=""

  if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
  fi

  # Валидация PORT (число 1024..65535)
  case "$PORT" in
    ''|*[!0-9]*)
      log_msg "WARN" "Некорректный PORT='$PORT', сброс на 1443"
      PORT=1443
      ;;
    *)
      if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
        log_msg "WARN" "PORT='$PORT' вне диапазона 1024-65535, сброс на 1443"
        PORT=1443
      fi
      ;;
  esac

  # Валидация HOST
  case "$HOST" in
    127.0.0.1|0.0.0.0|localhost) ;;
    *)
      case "$HOST" in
        *[!0-9.]*)
          log_msg "WARN" "Некорректный HOST='$HOST', сброс на 127.0.0.1"
          HOST="127.0.0.1"
          ;;
      esac
      ;;
  esac
  if [ "$HOST" = "0.0.0.0" ]; then
    log_msg "WARN" "HOST=0.0.0.0 открывает прокси для локальной сети"
  fi

  # Валидация числовых полей
  case "$POOL_SIZE" in ''|*[!0-9]*) POOL_SIZE=1 ;; esac
  case "$BUF_KB" in ''|*[!0-9]*) BUF_KB=64 ;; esac
  case "$MAX_CONNS" in ''|*[!0-9]*) MAX_CONNS=256 ;; esac
  case "$LOG_BACKUPS" in ''|*[!0-9]*) LOG_BACKUPS=1 ;; esac
  case "$CFPROXY_PRIORITY" in 0|1) ;; *) CFPROXY_PRIORITY="0" ;; esac
  case "$VERBOSE" in 0|1) ;; *) VERBOSE="0" ;; esac

  # Санитизация строковых параметров от инъекций
  clean_str() {
    local val="$1"
    case "$val" in
      *[\;\&\|\`\$\(\)]*) echo "" ;;
      *) echo "$val" ;;
    esac
  }

  FAKE_TLS_DOMAIN="$(clean_str "$FAKE_TLS_DOMAIN")"
  CFPROXY_DOMAINS="$(clean_str "$CFPROXY_DOMAINS")"
  CFPROXY_DOMAINS_URL="$(clean_str "$CFPROXY_DOMAINS_URL")"
  CFPROXY_WORKER_DOMAIN="$(clean_str "$CFPROXY_WORKER_DOMAIN")"
}

# Проверка принадлежности PID процессу
proc_matches() {
  local p="$1"
  local pattern="$2"
  if [ -n "$p" ] && [ -d "/proc/$p" ]; then
    if grep -a -q "$pattern" "/proc/$p/cmdline" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Получение проверенного PID демона
daemon_pid() {
  if [ -f "$PID_FILE" ]; then
    local p
    p="$(cat "$PID_FILE" 2>/dev/null | tr -d '\r\n ')"
    if proc_matches "$p" "tg-ws-proxy"; then
      echo "$p"
      return 0
    fi
    rm -f "$PID_FILE"
  fi
  return 1
}

# Получение проверенного PID супервизора
supervisor_pid() {
  if [ -f "$SUP_PID_FILE" ]; then
    local p
    p="$(cat "$SUP_PID_FILE" 2>/dev/null | tr -d '\r\n ')"
    if proc_matches "$p" "service.sh"; then
      echo "$p"
      return 0
    fi
    rm -f "$SUP_PID_FILE"
  fi
  return 1
}

# Проверка, слушает ли порт (через /proc/net/tcp)
is_listening() {
  local hp
  hp="$(printf '%04X' "$PORT" 2>/dev/null)"
  [ -z "$hp" ] && return 1
  while read -r _ la _ st _; do
    case "$la" in
      *:"$hp") [ "$st" = "0A" ] && return 0 ;;
    esac
  done < /proc/net/tcp 2>/dev/null
  return 1
}

# Сброс устаревших PID и блокировок при перезагрузке системы
reset_stale_state() {
  local cur_boot=""
  if [ -f "/proc/sys/kernel/random/boot_id" ]; then
    cur_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
  fi
  local old_boot=""
  [ -f "$BOOT_ID_FILE" ] && old_boot="$(cat "$BOOT_ID_FILE" 2>/dev/null)"

  if [ -n "$cur_boot" ] && [ "$cur_boot" != "$old_boot" ]; then
    rm -f "$PID_FILE" "$SUP_PID_FILE" "$HEALTH_FILE"
    rm -rf "$LOCK_DIR"
    mkdir -p "$RUN_DIR" 2>/dev/null
    echo "$cur_boot" > "$BOOT_ID_FILE"
  fi
}

# Проверка валидности hex-строки (32 hex символа)
is_valid_secret() {
  local s="$1"
  if [ "${#s}" -eq 32 ]; then
    case "$s" in
      *[!0-9a-fA-F]*) return 1 ;;
      *) return 0 ;;
    esac
  fi
  return 1
}

# Проверка и генерация постоянного секрета
ensure_secret() {
  # 1. Проверяем SECRET из config.conf
  if [ -n "$SECRET" ]; then
    if is_valid_secret "$SECRET"; then
      return 0
    else
      log_msg "ERROR" "SECRET в config.conf невалиден (требуется 32 hex символа). Используется сохранённый ключ."
      SECRET=""
    fi
  fi

  # 2. Проверяем secret.conf
  if [ -f "$SECRET_FILE" ]; then
    local saved_sec
    saved_sec="$(head -n 1 "$SECRET_FILE" 2>/dev/null | tr -d '\r\n ')"
    if is_valid_secret "$saved_sec"; then
      SECRET="$saved_sec"
      return 0
    fi
  fi

  # 3. Генерируем новый через бинарник
  local new_sec=""
  if [ -x "$BIN" ]; then
    new_sec="$("$BIN" -gen-secret 2>/dev/null | tr -d '\r\n ')"
  fi

  # Fallback генерации через urandom если бинарник не вернул
  if ! is_valid_secret "$new_sec"; then
    new_sec="$(head -c 16 /dev/urandom 2>/dev/null | od -A n -t x1 | tr -d ' \n')"
  fi

  if is_valid_secret "$new_sec"; then
    SECRET="$new_sec"
    mkdir -p "$STATE" 2>/dev/null
    printf '%s\n' "$SECRET" > "$SECRET_FILE.tmp.$$"
    mv -f "$SECRET_FILE.tmp.$$" "$SECRET_FILE"
    chmod 0600 "$SECRET_FILE"
    log_msg "INFO" "Сгенерирован и сохранён постоянный секрет MTProto"
    return 0
  fi

  log_msg "ERROR" "Не удалось сгенерировать валидный секрет MTProto!"
  return 1
}

# Сборка аргументов запуска демона
build_args() {
  ARGS="-host $HOST -port $PORT -secret $SECRET -buf-kb $BUF_KB -pool-size $POOL_SIZE -max-conns $MAX_CONNS -log-file $LOG -log-max-mb $LOG_MAX_MB -log-backups $LOG_BACKUPS"

  if [ -n "$FAKE_TLS_DOMAIN" ]; then
    ARGS="$ARGS -fake-tls-domain $FAKE_TLS_DOMAIN"
  fi

  if [ -n "$CFPROXY_DOMAINS" ]; then
    ARGS="$ARGS -cfproxy-domains $CFPROXY_DOMAINS"
  elif [ -n "$CFPROXY_DOMAINS_URL" ]; then
    ARGS="$ARGS -cfproxy-domains-url $CFPROXY_DOMAINS_URL"
  fi

  if [ -n "$CFPROXY_WORKER_DOMAIN" ]; then
    ARGS="$ARGS -cfproxy-worker-domain $CFPROXY_WORKER_DOMAIN"
  fi

  if [ "$CFPROXY_PRIORITY" = "0" ]; then
    ARGS="$ARGS -cfproxy-priority=false"
  fi

  if [ "$VERBOSE" = "1" ]; then
    ARGS="$ARGS -v"
  fi

  if [ -n "$EXTRA_ARGS" ]; then
    ARGS="$ARGS $EXTRA_ARGS"
  fi
}

# Генерация ссылки для подключения через бинарник (-print-link)
build_link() {
  local link=""
  if [ -x "$BIN" ] && [ -n "$SECRET" ]; then
    link="$("$BIN" -secret "$SECRET" -host "$HOST" -port "$PORT" ${FAKE_TLS_DOMAIN:+-fake-tls-domain "$FAKE_TLS_DOMAIN"} -print-link 2>/dev/null | tr -d '\r\n')"
  fi

  if [ -n "$link" ]; then
    mkdir -p "$RUN_DIR" 2>/dev/null
    printf '%s\n' "$link" > "$LINK_FILE.tmp.$$"
    mv -f "$LINK_FILE.tmp.$$" "$LINK_FILE"
    chmod 0644 "$LINK_FILE"
    echo "$link"
    return 0
  fi
  return 1
}

# Захват блокировки супервизора
acquire_lock() {
  local i=0
  while [ "$i" -lt 10 ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo $$ > "$LOCK_DIR/pid"
      return 0
    fi
    local lp
    lp="$(cat "$LOCK_DIR/pid" 2>/dev/null | tr -d '\r\n ')"
    if ! proc_matches "$lp" "service.sh"; then
      log_msg "WARN" "Удаление устаревшей блокировки супервизора (pid=$lp)"
      rm -rf "$LOCK_DIR"
    else
      return 1
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# Освобождение блокировки супервизора
release_lock() {
  rm -rf "$LOCK_DIR"
  rm -f "$SUP_PID_FILE"
}

# Остановка демона
stop_daemon() {
  local dpid
  dpid="$(daemon_pid)"
  if [ -n "$dpid" ]; then
    kill "$dpid" 2>/dev/null || true
    local i=0
    while [ "$i" -lt 3 ]; do
      if ! proc_matches "$dpid" "tg-ws-proxy"; then
        rm -f "$PID_FILE"
        return 0
      fi
      sleep 0.2 2>/dev/null || sleep 1
      i=$((i + 1))
    done
    kill -9 "$dpid" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  pkill -9 -x "tg-ws-proxy" 2>/dev/null || true
  killall -9 tg-ws-proxy 2>/dev/null || true
  rm -f "$PID_FILE"
  return 0
}

# Запуск демона и проверка готовности
start_daemon() {
  stop_daemon
  mkdir -p "$LOG_DIR" "$RUN_DIR" 2>/dev/null
  load_config
  ensure_secret
  build_args

  # Ротация stderr.log если больше 256 КБ
  if [ -f "$ERRLOG" ]; then
    local err_sz
    err_sz="$(wc -c < "$ERRLOG" 2>/dev/null || echo 0)"
    if [ "$err_sz" -gt 262144 ]; then
      mv -f "$ERRLOG" "$ERRLOG.1" 2>/dev/null
    fi
  fi

  log_msg "INFO" "Запуск демона tg-ws-proxy на ${HOST}:${PORT} (Pool=${POOL_SIZE}, Priority=${CFPROXY_PRIORITY})..."
  "$BIN" $ARGS >> "$ERRLOG" 2>&1 &
  local new_pid=$!
  echo "$new_pid" > "$PID_FILE"

  # Ожидание открытия сокета (до 10 секунд)
  local i=0
  local ready=0
  while [ "$i" -lt 10 ]; do
    if is_listening; then
      ready=1
      break
    fi
    if ! proc_matches "$new_pid" "tg-ws-proxy"; then
      break
    fi
    sleep 1
    i=$((i + 1))
  done

  if [ "$ready" = "1" ]; then
    log_msg "INFO" "Демон успешно запущен и слушает ${HOST}:${PORT} (PID: $new_pid)"
    printf 'STATUS=ok\nPID=%s\nPORT=%s\nTIME=%s\n' "$new_pid" "$PORT" "$(date '+%Y-%m-%d %H:%M:%S')" > "$HEALTH_FILE"
    build_link >/dev/null 2>&1
    return 0
  else
    log_msg "ERROR" "Сбой запуска демона tg-ws-proxy на ${HOST}:${PORT} (PID: $new_pid)!"
    if [ -f "$ERRLOG" ]; then
      log_msg "ERROR" "Последние ошибки stderr:"
      tail -n 5 "$ERRLOG" 2>/dev/null | while IFS= read -r l; do
        log_msg "ERROR" "  $l"
      done
    fi
    printf 'STATUS=fail\nPORT=%s\nTIME=%s\n' "$PORT" "$(date '+%Y-%m-%d %H:%M:%S')" > "$HEALTH_FILE"
    return 1
  fi
}

# Получение статуса в формате JSON для WebUI
get_status_json() {
  load_config
  local dpid spid listening link
  dpid="$(daemon_pid 2>/dev/null || echo "")"
  spid="$(supervisor_pid 2>/dev/null || echo "")"
  listening=false
  if is_listening; then
    listening=true
  fi

  link=""
  if [ -f "$LINK_FILE" ]; then
    link="$(cat "$LINK_FILE" 2>/dev/null | tr -d '\r\n')"
  fi
  [ -z "$link" ] && [ "$listening" = "true" ] && link="$(build_link 2>/dev/null)"

  printf '{"listening":%s,"daemon_pid":"%s","supervisor_pid":"%s","port":"%s","host":"%s","link":"%s","cf_worker":"%s","cf_priority":"%s","pool_size":"%s"}\n' \
    "$listening" "${dpid:-}" "${spid:-}" "${PORT:-1443}" "${HOST:-127.0.0.1}" "${link:-}" "${CFPROXY_WORKER_DOMAIN:-}" "${CFPROXY_PRIORITY:-0}" "${POOL_SIZE:-1}"
}

# Быстрый замер задержки (Latency / RTT) до Cloudflare-доменов (on-demand)
check_cf_latency() {
  load_config
  local domain_list="cloudflare.com 1.1.1.1 cdnjs.cloudflare.com workers.dev"
  if [ -n "$CFPROXY_DOMAINS" ]; then
    domain_list="$(echo "$CFPROXY_DOMAINS" | tr ',' ' ')"
  fi
  if [ -n "$CFPROXY_WORKER_DOMAIN" ]; then
    domain_list="$CFPROXY_WORKER_DOMAIN $domain_list"
  fi

  for dom in $domain_list; do
    [ -z "$dom" ] && continue
    local ping_out rtt
    ping_out="$(ping -c 1 -W 2 "$dom" 2>/dev/null | tail -n 1)"
    case "$ping_out" in
      *rtt*|*round-trip*|*min/avg/max*)
        rtt="$(echo "$ping_out" | awk -F'/' '{print $5}' | cut -d'.' -f1)"
        [ -n "$rtt" ] && printf '%s %s ms\n' "$dom" "$rtt" || printf '%s online\n' "$dom"
        ;;
      *)
        printf '%s timeout\n' "$dom"
        ;;
    esac
  done
}

